# SomlengSWITCH

[![Build](https://github.com/somleng/somleng-switch/actions/workflows/build.yml/badge.svg)](https://github.com/somleng/somleng-switch/actions/workflows/build.yml)
[![View performance data on Skylight](https://badges.skylight.io/status/Z5dVwBwcpWaW.svg)](https://oss.skylight.io/app/applications/Z5dVwBwcpWaW)
[![Codacy Badge](https://app.codacy.com/project/badge/Coverage/db2c6093e37746599a9d5c1b5b703715)](https://www.codacy.com/gh/somleng/somleng-switch/dashboard?utm_source=github.com&utm_medium=referral&utm_content=somleng/somleng-switch&utm_campaign=Badge_Coverage)

SomlengSWITCH (part of [The Somleng Project](https://github.com/somleng/somleng-project)) is used to programmatically control phone calls through FreeSWITCH.

This repository includes the following core features:

* [Open Source TwiML parser](https://github.com/somleng/somleng-switch/blob/develop/app/models/execute_twiml.rb)
* [FreeSWITCH configuration files](https://github.com/somleng/somleng-switch/tree/develop/components/freeswitch)
* [Terraform infrastructure as code](https://github.com/somleng/somleng-switch/tree/develop/infrastructure) for deployment to AWS

## Usage

In order to get the full Somleng stack up and running on your development machine, please follow the [GETTING STARTED](https://github.com/somleng/somleng-project/blob/master/docs/GETTING_STARTED.md) guide.

## Local Deployment

After installation, further changes can be made to underlying [adhearsion](https://github.com/adhearsion/adhearsion) library installed at `components/app/vendor/bundle/ruby/2.7.0/bundler/gems/adhearsion-7ae88e1bd865/lib/adhearsion`.

Update the default initial property for Class `Call` - `call_handup` to `false` otherwise the call drops immediately (
`components/app/vendor/bundle/ruby/2.7.0/bundler/gems/adhearsion-7ae88e1bd865/lib/adhearsion/call.rb`).

### Docker
Start the docker instance for ruby where the repo is cloned:
```
docker run --rm -w /app --net=host -v ${PWD}/components/app:/app -it ruby:2.7 bash
```

Setup the Instance for usage:
```
apt update
apt install curl libpcre2-posix2 libpcre2-dev build-essential git postgresql nodejs vim screen iproute2 net-tools -y
```

Setup and launch the application:
```
bundle config --local deployment true
bundle config --local path "vendor/bundle"
bundle config --local without 'development test'
bundle install --jobs 20 --retry 5
yarn install --frozen-lockfile
bundle exec rails assets:precompile
mkdir -p tmp/pids

# Start the application
# Necessary config changes can be made in config/app_settings.yml
bundle exec ahn start --no-console
```

### MacOS
Preliminary installation:
```
brew install ruby@2.7 # Ruby 2.7
brew install libpq # PostgreSQL Client
brew install pcre
```

Setup and launch the application:
```
export CPATH="/opt/homebrew/include:/opt/homebrew/Cellar/libpq/15.1/include:$CPATH"
export PATH="/opt/homebrew/opt/ruby@2.7/bin:/opt/homebrew/opt/libpq/bin:$PATH"
bundle config --local deployment true
bundle config --local path "vendor/bundle"
bundle config --local without 'development test'
bundle install --jobs 20 --retry 5
bundle exec rails assets:precompile
mkdir -p tmp/pids

# Start the application
# Necessary config changes can be made in config/app_settings.yml
bundle exec ahn start --no-console
```

## Deployment

The [infrastructure directory](https://github.com/somleng/somleng-switch/tree/develop/infrastructure) contains [Terraform](https://www.terraform.io/) configuration files in order to deploy SomlengSWITCH to AWS.

:warning: The current infrastructure of Somleng is rapidly changing as we continue to improve and experiment with new features. We often make breaking changes to the current infrastructure which usually requires some manual migration. We don't recommend that you try to deploy and run your own Somleng stack for production purposes at this stage.

The infrastructure in this repository depends on some shared core infrastructure. This core infrastructure can be found in the [Somleng Project](https://github.com/somleng/somleng-project/tree/master/infrastructure) repository.

The current infrastructure deploys SomlengSWITCH to AWS behind a Network Load Balancer (NLB) to Elastic Container Service (ECS). There is one task, which runs three containers. An [NGINX container](https://github.com/somleng/somleng-switch/blob/develop/components/nginx/Dockerfile) which runs as a reverse proxy to the [Adhearsion container](https://github.com/somleng/somleng-switch/blob/develop/Dockerfile) which accepts API requests from Somleng. There's also a [FreeSWITCH container](https://github.com/somleng/somleng-switch/blob/develop/components/freeswitch/Dockerfile) which handles SIP connections to operators.

## License

The software is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
