FROM alpine:3.14.5

RUN apk update \
 && apk add bash curl

CMD ["bash"]
