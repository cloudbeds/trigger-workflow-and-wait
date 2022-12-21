FROM node:16 as build
WORKDIR /app
ADD github-app-token/ .
RUN yarn install --frozen-lockfile && yarn run build

FROM node:16

RUN apt update && \
	apt install -y jq coreutils && \
	apt-get clean

RUN mkdir /github-app-token
COPY --from=build /app/dist /github-app-token/
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["bash", "/entrypoint.sh"]
