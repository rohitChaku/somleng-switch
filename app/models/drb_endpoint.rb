class DrbEndpoint
  DEFAULT_DIAL_STRING_FORMAT = "%{destination}"

  attr_accessor :call_params, :destination, :destination_host,
                :caller_id, :dial_string_format, :dial_string, :gateway,
                :voice_request_url, :voice_request_method,
                :status_callback_url, :status_callback_method,
                :call_sid, :account_sid, :auth_token, :disable_originate,
                :outbound_call, :answered, :outbound_call_sid, :call_to, :call_from

  def initiate_outbound_call!(call_json)
    logger.info("Receiving DRb request: #{call_json}")
    self.call_params = JSON.parse(call_json)
    setup_call_variables

    call_args = [
      dial_string,
      {
        :from => caller_id,
        :controller => CallController,
        :controller_metadata => controller_metadata
      }
    ]

    if originate_call?
      logger.info("Initiating outbound call with: #{call_args}")
      self.outbound_call = Adhearsion::OutboundCall.originate(*call_args)
      twilio_call = Adhearsion::Twilio::Call.new(outbound_call)
      self.call_to = twilio_call.to
      self.call_from = twilio_call.from
      register_event_answered
      register_event_end
      self.outbound_call_sid = outbound_call.id
    end
  end

  private

  def configuration
    @configuration ||= Adhearsion::Twilio::Configuration.new
  end

  def register_event_answered
    outbound_call.register_event_handler(Adhearsion::Event::Answered) do
      handle_event_answered
    end
  end

  def register_event_end
    outbound_call.register_event_handler(Adhearsion::Event::End) do
      handle_event_end
    end
  end

  def handle_event_answered
    self.answered = true
  end

  def handle_event_end
    logger.info("Call Ended. Executing custom event handler for Adhearsion::Event::End")
    notify_status_callback_url
  end

  def notify_status_callback_url
    logger.info("Notifying status_callback_url. Call answered?: #{answered?}")
    http_client.notify_status_callback_url(:no_answer) if !answered?
  end

  def answered?
    !!answered
  end

  def http_client
    @http_client ||= Adhearsion::Twilio::HttpClient.new(
      :status_callback_url => status_callback_url || configuration.status_callback_url,
      :status_callback_method => status_callback_method || configuration.status_callback_method,
      :call_sid => outbound_call_sid,
      :call_to => call_to,
      :call_from => call_from,
      :call_direction => call_direction,
      :auth_token => auth_token,
      :logger => logger
    )
  end

  def call_direction
    :outbound_api
  end

  def originate_call?
    disable_originate.to_i != 1
  end

  def routing_instructions
    call_params["routing_instructions"] || {}
  end

  def controller_metadata
    {
      :voice_request_url => voice_request_url,
      :voice_request_method => voice_request_method,
      :status_callback_url => status_callback_url,
      :status_callback_method => status_callback_method,
      :account_sid => account_sid,
      :auth_token => auth_token,
      :call_sid => call_sid,
      :call_direction => call_direction,
      :rest_api_enabled => false
    }
  end

  def setup_call_variables
    self.voice_request_url = call_params["voice_url"]
    self.voice_request_method = call_params["voice_method"]
    self.status_callback_url = call_params["status_callback_url"]
    self.status_callback_method = call_params["status_callback_method"]
    self.account_sid = call_params["account_sid"]
    self.auth_token = call_params["account_auth_token"]
    self.call_sid = call_params["sid"]

    self.caller_id = routing_instructions["source"] || call_params["from"] || default_caller_id
    self.destination = routing_instructions["destination"] || call_params["to"] || default_destination
    self.destination_host = routing_instructions["destination_host"] || default_destination_host
    self.gateway = routing_instructions["gateway"] || default_gateway
    self.dial_string_format = routing_instructions["dial_string_format"] || default_dial_string_format
    self.dial_string = routing_instructions["dial_string"] || default_dial_string || generate_dial_string
    self.disable_originate = routing_instructions["disable_originate"] || default_disable_originate
  end

  def generate_dial_string
    dial_string_format.sub(
      /\%\{destination\}/, destination.to_s
    ).sub(
      /\%\{destination_host\}/, destination_host.to_s
    ).sub(
      /\%\{gateway\}/, gateway.to_s
    )
  end

  def default_destination
    ENV["AHN_SOMLENG_DEFAULT_DESTINATION"]
  end

  def default_destination_host
    ENV["AHN_SOMLENG_DEFAULT_DESTINATION_HOST"]
  end

  def default_dial_string
    ENV["AHN_SOMLENG_DEFAULT_DIAL_STRING"]
  end

  def default_gateway
    ENV["AHN_SOMLENG_DEFAULT_GATEWAY"]
  end

  def default_dial_string_format
    ENV["AHN_SOMLENG_DEFAULT_DIAL_STRING_FORMAT"] || DEFAULT_DIAL_STRING_FORMAT
  end

  def default_caller_id
    ENV["AHN_SOMLENG_DEFAULT_CALLER_ID"]
  end

  def default_disable_originate
    ENV["AHN_SOMLENG_DISABLE_ORIGINATE"]
  end
end
