FROM public.ecr.aws/rolesanywhere/credential-helper:1.8.1-2026.04.09.16.01 AS aws_signing_helper

FROM busybox:1.37.0
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /opt/usr/src_files
COPY --from=aws_signing_helper / /usr/local/bin/aws_signing_helper ./
ENTRYPOINT [ "/entrypoint.sh" ]