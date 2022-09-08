# Base image
ARG BASE_IMAGE=quay.io/centos/centos:stream8
FROM $BASE_IMAGE as base

# Some packages requires building, so use different stage for that
FROM base as builder
RUN dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False gcc make && \
    useradd --create-home --system --user-group build
# Build su-exec
COPY su-exec.c /tmp/
RUN gcc -Wall -Werror -g -o /usr/local/bin/su-exec /tmp/su-exec.c && \
    chmod u+x /usr/local/bin/su-exec

# Build PHP extensions that are not included in packages
FROM builder as php-build
COPY bin/misp_compile_php_extensions.sh bin/misp_enable_epel.sh /build/
RUN --mount=type=tmpfs,target=/tmp \
    dnf module enable -y php:7.4 && \
    bash /build/misp_enable_epel.sh && \
    bash /build/misp_compile_php_extensions.sh

# Build jobber, that is not released for arm64 arch
FROM builder as jobber-build
COPY bin/misp_compile_jobber.sh /build/
RUN --mount=type=tmpfs,target=/tmp bash /build/misp_compile_jobber.sh

# MISP image
FROM base as misp

# Install required system and Python packages
COPY packages /tmp/packages
COPY requirements.txt /tmp/
COPY bin/misp_enable_epel.sh /usr/local/bin/
RUN bash /usr/local/bin/misp_enable_epel.sh && \
    dnf module -y enable mod_auth_openidc php:7.4 python39 && \
    dnf install --setopt=tsflags=nodocs --setopt=install_weak_deps=False -y $(grep -vE "^\s*#" /tmp/packages | tr "\n" " ") && \
    dnf install -y nss_wrapper gettext && \
    dnf install -y telnet tcpdump && \
    alternatives --set python3 /usr/bin/python3.9 && \
    pip3 --no-cache-dir install --disable-pip-version-check -r /tmp/requirements.txt && \
    rm -rf /var/cache/dnf /tmp/packages

RUN useradd misp-user

COPY --from=builder /usr/local/bin/su-exec /usr/local/bin/
COPY --from=php-build /build/php-modules/* /usr/lib64/php/modules/
COPY --from=jobber-build /build/jobber*.rpm /tmp
COPY bin/ /usr/local/bin/
COPY misp.conf /etc/httpd/conf.d/misp.conf
COPY httpd-errors/* /var/www/html/
COPY rsyslog.conf /etc/
COPY snuffleupagus-misp.rules /etc/php.d/
COPY .jobber /root/
COPY supervisor.ini /etc/supervisord.d/misp.ini
COPY logrotate/* /etc/logrotate.d/

ARG CACHEBUST=1
ARG MISP_VERSION=develop
ENV MISP_VERSION $MISP_VERSION

RUN rpm -i /tmp/jobber*.rpm && \
    chmod u=rwx,g=rx,o=rx /usr/local/bin/* &&  \
    /usr/local/bin/misp_install.sh
COPY Config/* /var/www/MISP/app/Config/
RUN chmod u=r,g=r,o=r /var/www/MISP/app/Config/* && \
    chmod 644 /etc/supervisord.d/misp.ini && \
    chmod 644 /etc/rsyslog.conf && \
    chmod 644 /etc/httpd/conf.d/misp.conf && \
    chmod 644 /etc/php.d/snuffleupagus-misp.rules && \
    chmod 644 /etc/logrotate.d/* && \
    chmod 644 /root/.jobber && \
    mkdir /run/php-fpm

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

# for debug
RUN chmod 664 /etc/supervisord.d/misp.ini
 
# Verify image
FROM misp as verify
RUN touch /verified && \
    chgrp -R 0 /verified && \
    chown -R misp-user /verified && \
    chmod -R g=u /verified
USER misp-user
RUN  exec /usr/local/bin/misp_verify.sh

# Final image
FROM misp
USER misp-user
# Hack that will force run verify stage
COPY --from=verify /verified /

ENV GNUPGHOME /var/www/MISP/.gnupg

VOLUME /var/www/MISP/app/tmp/logs/
VOLUME /var/www/MISP/app/files/certs/
VOLUME /var/www/MISP/app/attachments/
VOLUME /var/www/MISP/.gnupg/

WORKDIR /var/www/MISP/
USER misp-user
# Web server
EXPOSE 8080
# ZeroMQ
EXPOSE 50000
# This is a hack how to go trought mod_auth_openidc
HEALTHCHECK CMD su-exec apache curl -H "Authorization: dummydummydummydummydummydummydummydummy" --fail http://127.0.0.1/fpm-status || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
