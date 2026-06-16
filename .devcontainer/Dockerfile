FROM ruby:3.4-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV BUNDLE_PATH=/workspace/vendor/bundle

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    default-libmysqlclient-dev \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN gem install bundler

CMD ["bash"]
