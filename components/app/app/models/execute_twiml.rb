class ExecuteTwiML
  URL_PATTERN = URI::DEFAULT_PARSER.make_regexp(%w[http https]).freeze

  attr_reader :context, :twiml

  delegate :logger, to: :context
  delegate :ask, :dial, :say, :play_audio, :redirect, :record,
           :call_platform_client, :call_properties, to: :context

  NESTED_GATHER_VERBS = %w[Say Play].freeze
  MAX_LOOP = 100
  SLEEP_BETWEEN_REDIRECTS = 1
  DEFAULT_TWILIO_VOICE = "man".freeze
  DEFAULT_TWILIO_LANGUAGE = "en".freeze
  FINISH_ON_KEY_PATTERN = /\A(?:\d|\*|\#)\z/.freeze
  DIAL_CALL_STATUSES = {
    no_answer: "no-answer",
    answer: "completed",
    timeout: "no-answer",
    error: "failed",
    busy: "busy",
    in_progress: "in-progress",
    ringing: "ringing"
  }.freeze

  def initialize(context:, twiml:)
    @context = context
    @twiml = twiml
  end

  def self.call(*args)
    new(*args).call
  end

  def call
    redirect_args = catch(:redirect) do
      twiml_doc.each do |verb|
        next if verb.comment?

        case verb.name
        when "Reject"
          execute_reject(verb)
          break
        when "Play"
          execute_play(verb)
        when "Gather"
          execute_gather(verb)
        when "Redirect"
          execute_redirect(verb)
        when "Say"
          execute_say(verb)
        when "Dial"
          execute_dial(verb)
        when "Hangup"
          break
        when "Record"
          execute_record(verb)
        else
          raise Errors::TwiMLError, "Invalid element '#{verb.name}'"
        end
      end

      false
    end

    redirect(*redirect_args) if redirect_args.present?
  rescue Errors::TwiMLError => e
    logger.error(e.message)
  end

  def answer(headers = {})
    context.answer(sip_headers.reverse_merge(headers))
  end

  def reject(reason, headers = {})
    context.reject(reason, sip_headers.reverse_merge(headers))
  end

  private

  def phone_call
    context.call
  end

  def answered?
    return if phone_call.blank?

    phone_call.answer_time.present?
  end

  def execute_reject(verb)
    attributes = twiml_attributes(verb)
    reject(attributes["reason"] == "busy" ? :busy : :decline)
  end

  def execute_play(verb)
    answer unless answered?

    twiml_loop(twiml_attributes(verb)).each do
      play_audio(verb.content)
    end
  end

  def execute_say(verb)
    answer unless answered?

    attributes = twiml_attributes(verb)

    twiml_loop(attributes).each do
      say(say_options(verb.content, attributes))
    end
  end

  def execute_redirect(verb)
    raise Errors::TwiMLError, "Redirect must contain a URL" if verb.content.blank?

    answer unless answered?

    sleep(SLEEP_BETWEEN_REDIRECTS)

    attributes = twiml_attributes(verb)
    throw(:redirect, [verb.content, attributes["method"]])
  end

  def execute_gather(verb)
    answer unless answered?

    attributes = twiml_attributes(verb)

    ask_params = verb.children.each_with_object([]) do |nested_verb, result|
      unless NESTED_GATHER_VERBS.include?(nested_verb.name)
        raise Errors::TwiMLError, "Nested verb <#{nested_verb.name}> not allowed within <Gather>"
      end

      nested_verb_attributes = twiml_attributes(nested_verb)
      content = nested_verb.name == "Say" ? say_options(nested_verb.content, nested_verb_attributes) : nested_verb.content
      result.concat(Array.new(twiml_loop(nested_verb_attributes).count, content))
    end

    ask_options = {}
    ask_options[:timeout] = attributes.fetch("timeout", 5).to_i.seconds
    ask_options[:limit] = attributes["numDigits"].to_i if attributes["numDigits"]

    if attributes["finishOnKey"] != ""
      ask_options[:terminator] = "#"
      if FINISH_ON_KEY_PATTERN.match?(attributes["finishOnKey"])
        ask_options[:terminator] = attributes.fetch("finishOnKey")
      end
    end

    ask_result = ask(*ask_params, ask_options)

    digits = ask_result.utterance
    if digits.present? || attributes["actionOnEmptyResult"] == "true"
      throw(
        :redirect,
        [
          attributes["action"],
          attributes["method"],
          (digits.present? ? { "Digits" => digits } : {})
        ]
      )
    end
  end

  def execute_dial(verb)
    answer unless answered?
    attributes = twiml_attributes(verb)

    to = verb.children.each_with_object({}) do |nested_noun, result|
      dial_content = nested_noun.content.strip

      if nested_noun.text? || nested_noun.name == "Number"
        routing_parameters = build_routing_parameters(dial_content)
      elsif nested_noun.name == "Sip"
        routing_parameters = {
          address: dial_content.delete_prefix("sip:")
        }
      end

      dial_string = DialString.new(routing_parameters).to_s

      break dial_string if nested_noun.text?

      unless ["Number", "Sip"].include?(nested_noun.name)
        raise Errors::TwiMLError, "Nested noun <#{nested_noun.name}> not allowed within <Dial>"
      end

      nested_noun_attributes = twiml_attributes(nested_noun)
      result[dial_string] = {
        from: nested_noun_attributes["callerId"],
        ringback: nested_noun_attributes["ringToneUrl"]
      }.compact
    end

    dial_status = dial(
      to,
      {
        from: attributes["callerId"],
        ringback: attributes["ringToneUrl"],
        for: attributes.fetch("timeout", 30).to_i.seconds
      }.compact
    )

    return if attributes["action"].blank?

    dial_call_status_params = {}
    dial_call_status_params["DialCallStatus"] = DIAL_CALL_STATUSES[dial_status.result]

    # try to find the joined call
    outbound_call = dial_status.joins.select do |_outbound_leg, join_status|
      join_status.result == :joined
    end.keys.first

    if outbound_call
      dial_call_status_params["DialCallSid"] = outbound_call.id
      dial_call_status_params["DialCallDuration"] = dial_status.joins[outbound_call].duration.to_i
    end

    throw(
      :redirect,
      [
        attributes["action"],
        attributes["method"],
        dial_call_status_params
      ]
    )
  end

  def execute_record(verb)
    attributes = twiml_attributes(verb)
    recording_api_params = { phone_call_id: call_properties.call_sid }
    recording_api_params["status_callback_url"] = attributes["recordingStatusCallback"]
    recording_api_params["status_callback_method"] = attributes["recordingStatusCallbackMethod"]
    recording_response = call_platform_client.create_recording(recording_api_params.compact)

    record_options = {}
    record_options[:max_duration] = attributes.fetch("maxLength", 3600).to_i
    record_options[:final_timeout] = attributes.fetch("timeout", 5).to_i
    record_options[:start_beep] = attributes["playBeep"] != "false"
    record_options[:interruptible] = attributes.fetch("finishOnKey", "1234567890*#")
    record_result = record(record_options)

    recording_response = call_platform_client.update_recording(
      recording_response.id,
      raw_recording_url: normalize_recording_url(record_result.recording.uri),
      external_id: record_result.component_id
    )

    throw(
      :redirect,
      [
        attributes["action"],
        attributes["method"],
        {
          "RecordingUrl" => recording_response.url,
          "RecordingDuration" => record_result.recording.duration.to_i / 1000
        }
      ]
    )
  end

  def say_options(content, attributes)
    voice_params = {
      name: attributes.fetch("voice", DEFAULT_TWILIO_VOICE),
      language: attributes.fetch("language", DEFAULT_TWILIO_LANGUAGE)
    }

    ssml = RubySpeech::SSML.draw do
      voice(voice_params) do
        # mod ssml doesn't support non-ascii characters
        # https://github.com/signalwire/freeswitch/issues/1348
        string(content + ".")
      end
    end
    ssml.document.encoding = "UTF-8"
    ssml
  end

  def twiml_loop(attributes)
    return MAX_LOOP.times if attributes["loop"].to_s == "0"

    [attributes.fetch("loop", 1).to_i, MAX_LOOP].min.times
  end

  def twiml_attributes(node)
    node.attributes.each_with_object({}) do |(key, attribute), options|
      options[key] = attribute.value
    end
  end

  def build_routing_parameters(number)
    call_platform_client.build_routing_parameters(
      phone_number: number,
      account_sid: call_properties.account_sid
    )
  end

  def twiml_doc
    doc = ::Nokogiri::XML(twiml.strip) do |config|
      config.options = Nokogiri::XML::ParseOptions::NOBLANKS
    end

    raise(Errors::TwiMLError, "The root element must be the '<Response>' element") if doc.root.name != "Response"

    doc.root.children
  rescue Nokogiri::XML::SyntaxError => e
    raise Errors::TwiMLError, "Error while parsing XML: #{e.message}. XML Document: #{content}"
  end

  def sip_headers
    call_properties.sip_headers.to_h
  end

  def normalize_recording_url(raw_recording_url)
    URL_PATTERN.match(raw_recording_url)[0]
  end
end
