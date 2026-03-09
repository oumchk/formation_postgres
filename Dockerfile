FROM ubuntu:24.04

ENV TERM=xterm-256color
ENV LANG=fr_FR.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl wget git vim nano \
    net-tools iputils-ping \
    python3 python3-pip \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root/travaux

CMD ["bash"]
