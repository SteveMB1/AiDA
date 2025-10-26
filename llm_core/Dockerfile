ARG BASE_IMAGE
FROM ${BASE_IMAGE}

LABEL authors="sbain@creativeradicals.com"

#RUN #adduser limited_user

COPY ./src /QASource

#RUN #chown -R limited_user.limited_user /QASource

#USER limited_user
WORKDIR /QASource
CMD ["./run.sh"]
EXPOSE 8000