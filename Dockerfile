FROM alpine

RUN apk update \
 && apk add bash curl

CMD ["bash"]
