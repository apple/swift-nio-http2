ARG swift_version=5.7
ARG ubuntu_version=focal
ARG base_image=swift:$swift_version-$ubuntu_version
FROM $base_image
# needed to do again after FROM due to docker limitation
ARG swift_version
ARG ubuntu_version

# set as UTF-8
RUN apt-get update && apt-get install -y locales locales-all
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8

# dependencies
RUN apt-get update && apt-get install -y wget
RUN apt-get update && apt-get install -y lsof dnsutils netcat-openbsd net-tools curl jq # used by integration tests

# ruby for soundness
RUN apt-get update && apt-get install -y ruby ruby-dev libsqlite3-dev build-essential

# tools
RUN mkdir -p $HOME/.tools
RUN echo 'export PATH="$HOME/.tools:$PATH"' >> $HOME/.profile

# script to allow mapping framepointers on linux (until part of the toolchain)
RUN wget -q https://raw.githubusercontent.com/apple/swift/main/utils/symbolicate-linux-fatal -O $HOME/.tools/symbolicate-linux-fatal
RUN chmod 755 $HOME/.tools/symbolicate-linux-fatal

# h2spec
ARG h2spec_version
RUN [ -z $h2spec_version ] || wget -q https://github.com/summerwind/h2spec/releases/download/v$h2spec_version/h2spec_linux_amd64.tar.gz -O $HOME/.tools/h2spec.tar.gz
RUN [ -z $h2spec_version ] || tar xzf $HOME/.tools/h2spec.tar.gz --directory $HOME/.tools
