FROM rockylinux:9.3.20231119

# Install EPEL and required system packages
RUN yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm crypto-policies-scripts
RUN yum -y update

RUN yum -y install jemalloc fontconfig langpacks-en
ENV LD_PRELOAD=/usr/lib64/libjemalloc.so.2

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN yum install -y python3-pip python3-devel python3 python3-protobuf
RUN yum install -y htop git openssh-clients tini

LABEL authors="sbain@creativeradicals.com"

# Clean up
RUN yum clean all && rm -rf /var/cache/yum

# Install Python dependencies
RUN pip3 install torch numpy requests && \
    pip3 install aioboto3 ansible ansible-runner elasticsearch==8.17.2 \
    fastapi aiohttp uvicorn uvloop wheel packaging tools PyJWT ldap3 openai

# Copy source code
COPY ./src /QASource

# Add non-root user
RUN adduser limited_user
RUN chown -R limited_user.limited_user /QASource
USER limited_user

WORKDIR /QASource

RUN python3 generate_jwt_secret.py

# ✅ Use Tini as the init system (reaps zombies)
ENTRYPOINT ["/usr/bin/tini", "--"]

# Your app entrypoint (unchanged)
CMD ["./run.sh"]

EXPOSE 8000
