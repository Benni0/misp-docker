# Base image
ARG BASE_IMAGE=almalinux:8
FROM $BASE_IMAGE AS base

# Some packages requires building, so use different stage for that
FROM base AS builder
COPY su-exec.c /tmp/
RUN dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False gcc-toolset-13 make && \
    source scl_source enable gcc-toolset-13 && \
    gcc -Wall -Werror -g -o /usr/local/bin/su-exec /tmp/su-exec.c

# Build PHP extensions that are not included in packages
FROM builder AS php-build
COPY bin/misp_compile_php_extensions.sh bin/misp_enable_epel.sh /build/
RUN --mount=type=tmpfs,target=/tmp \
    dnf module enable -y php:7.4 && \
    bash /build/misp_enable_epel.sh && \
    bash /build/misp_compile_php_extensions.sh

# Build jobber, that is not released for arm64 arch
FROM builder AS jobber-build
COPY bin/misp_compile_jobber.sh /build/
RUN bash /build/misp_compile_jobber.sh

# Build zlib-ng, faster alternative of zlib library
FROM builder AS zlib-ng-build
COPY bin/misp_compile_zlib_ng.sh /build/
RUN bash /build/misp_compile_zlib_ng.sh

# MISP image
FROM base AS misp

# Install required system and Python packages
COPY requirements.txt packages /tmp/
COPY bin/misp_enable_epel.sh bin/misp_enable_vector.sh /usr/local/bin/
RUN bash /usr/local/bin/misp_enable_epel.sh && \
    bash /usr/local/bin/misp_enable_vector.sh && \
    dnf module -y enable mod_auth_openidc php:7.4 && \
    dnf install --setopt=tsflags=nodocs --setopt=install_weak_deps=False -y $(grep -vE "^\s*#" /tmp/packages | tr "\n" " ") && \
    dnf install -y nss_wrapper gettext && \
    dnf install -y telnet tcpdump && \
    alternatives --set python3 /usr/bin/python3.11 && \
    alternatives --set python /usr/bin/python3.11 && \
    pip3 --no-cache-dir install --disable-pip-version-check -r /tmp/requirements.txt && \
    mkdir /run/php-fpm && \
    rm -rf /tmp/packages

RUN useradd misp-user

COPY --from=builder --chmod=775 /usr/local/bin/su-exec /usr/local/bin/
COPY --from=php-build /build/php-modules/* /usr/lib64/php/modules/
COPY --from=jobber-build /build/jobber*.rpm /tmp
COPY --from=zlib-ng-build /build/libz.so.1.3.1.zlib-ng /lib64/
COPY --chmod=775 bin/ /usr/local/bin/
COPY --chmod=664 misp.conf /etc/httpd/conf.d/misp.conf
COPY --chmod=664 httpd-errors/* /var/www/html/
COPY --chmod=664 vector.yaml /etc/vector/
COPY --chmod=664 rsyslog.conf /etc/
COPY --chmod=664 snuffleupagus-misp.rules /etc/php.d/
COPY --chmod=664 .jobber /root/
COPY --chmod=664 supervisor.ini /etc/supervisord.d/misp.ini
COPY --chmod=664 logrotate/* /etc/logrotate.d/

RUN update-crypto-policies

ARG CACHEBUST=1
ARG MISP_VERSION=2.4
ENV MISP_VERSION=$MISP_VERSION

RUN ln -f -s /lib64/libz.so.1.3.1.zlib-ng /lib64/libz.so.1 && \
    rpm -i /tmp/jobber*.rpm && \
    /usr/local/bin/misp_install.sh
COPY --chmod=444 Config/* /var/www/MISP/app/Config/
COPY --chmod=444 patches/cake.php /var/www/MISP/app/Console/

RUN sed -i -e 's/ProcessTool::whoami()/"httpd"/g' /var/www/MISP/app/Console/Command/AdminShell.php
    
RUN chgrp -R 0 /var/www/MISP && chown -R misp-user /var/www/MISP && chmod -R g=u /var/www/MISP
RUN chmod g+w /var/www/MISP/app/Config/database.php
RUN chmod g+w /var/www/MISP/app/Config/config.php
RUN chmod g+w /var/www/MISP/app/Config/email.php
RUN touch /etc/php.d/40-snuffleupagus.ini && chgrp 0 /etc/php.d/40-snuffleupagus.ini && chmod g+w /etc/php.d/40-snuffleupagus.ini
RUN touch /etc/php-fpm.d/sessions.conf && chgrp 0 /etc/php-fpm.d/sessions.conf && chmod g+w /etc/php-fpm.d/sessions.conf
RUN touch /etc/httpd/conf.d/misp.conf && chgrp 0 /etc/httpd/conf.d/misp.conf && chmod g+w /etc/httpd/conf.d/misp.conf
RUN touch /etc/rsyslog.d/file.conf && chgrp 0 /etc/rsyslog.d/file.conf && chmod g+w /etc/rsyslog.d/file.conf
RUN chgrp -R 0 /var/www/html && chown -R misp-user /var/www/html && chmod -R g=u /var/www/html
RUN touch /etc/php.d/99-misp.ini && chgrp 0 /etc/php.d/99-misp.ini && chmod g+w /etc/php.d/99-misp.ini
RUN chgrp 0 /etc/crypto-policies/config && chmod g+w /etc/crypto-policies/config
# Todo: change jobber
RUN touch /root/.jobber && chgrp 0 /root/.jobber && chmod g+w /root/.jobber
RUN chgrp 0 /var/log/supervisor && chmod 770 /var/log/supervisor
RUN sed -i -e 's/80/8080/g' /etc/httpd/conf/httpd.conf
RUN chmod -R g=u /var/log
RUN chmod 777 /var/log/httpd
#RUN chmod -R g=u /var/run
RUN chown -R apache:root /var/run/httpd
RUN chmod -R g=u /var/run/httpd
RUN chmod -R g=u /var/run/php-fpm
#RUN touch /var/run/rsyslogd.pid
#RUN chmod 777 /var/run/rsyslogd.pid
RUN chmod -R g=u /var/run/supervisor
RUN touch /var/run/supervisord.pid
RUN chmod g=u /var/run/supervisord.pid
RUN chmod g=u /run
#RUN chmod -R g=u /var/run/ chmod -R g=u /var/run/supervisor
RUN mkdir /var/jobber && chgrp 0 /var/jobber && chmod g=u /var/jobber
RUN mkdir /var/jobber/0 && chown root:root /var/jobber/0 && chmod g=u /var/jobber/0

COPY passwd.template /root/passwd.template
RUN chmod g=u /root/passwd.template

RUN mkdir /var/www/MISP/.gnupg
RUN chown -R apache:root /var/www/MISP/.gnupg
RUN chmod 770 /var/www/MISP/.gnupg

# for debug
RUN chmod 664 /etc/supervisord.d/misp.ini

# Verify image
FROM misp AS verify
RUN touch /verified && \
    chgrp -R 0 /verified && \
    chown -R misp-user /verified && \
    chmod -R g=u /verified && \
    /usr/bin/vector --config-dir /etc/vector/ validate


# Final image
FROM misp
USER misp-user
# Hack that will force run verify stage
COPY --from=verify /verified /

ENV LD_PRELOAD=/usr/lib64/libjemalloc.so.2
ENV GNUPGHOME=/var/www/MISP/.gnupg

VOLUME /var/www/MISP/app/tmp/logs/
VOLUME /var/www/MISP/app/files/certs/
VOLUME /var/www/MISP/app/attachments/
VOLUME /var/www/MISP/app/files/img/orgs/
VOLUME /var/www/MISP/app/files/img/custom/
VOLUME /var/www/MISP/.gnupg/

WORKDIR /var/www/MISP/
USER misp-user
# Web server
EXPOSE 8080
# ZeroMQ
EXPOSE 50000
HEALTHCHECK CMD su-exec apache misp_status.py
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
