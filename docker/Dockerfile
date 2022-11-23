FROM docker.elastic.co/logstash/logstash:8.2.2

USER root
RUN mkdir -p /etc/logstash && \
    rm -rf /usr/share/logstash/pipeline_aggregate

#Install redis gem for use in filters - needs java and jruby in path
RUN PATH=$PATH:/usr/share/logstash/jdk/bin:/usr/share/logstash/vendor/jruby/bin gem install redis

#Install Maven so we can add java libs for use in JRuby and ansible for config-generate
RUN apt-get update -y && apt-get install -y maven ansible

COPY --chown=logstash:root conf /usr/share/logstash/config
COPY --chown=logstash:root java /usr/lib/stardust/pipeline/java
COPY --chown=logstash:root ruby /usr/lib/stardust/pipeline/ruby
COPY --chown=logstash:root pipeline_aggregate /usr/share/logstash/pipeline_aggregate/
COPY --chown=logstash:root pipeline_ingest /usr/share/logstash/pipeline_ingest/
COPY --chown=logstash:root pipeline_etc /etc/stardust/pipeline/

#Generate mappings.yaml from includes
COPY --chown=logstash:root ansible /tmp/ansible/
RUN cd /tmp/ansible/ && \
        ln -s /etc/stardust/pipeline/ ../pipeline_etc && \
        ansible-playbook -i inventory docker_config_no_vaults.yml -t docker_build && \
        cd ../ && \
        unlink /tmp/pipeline_etc && \
        rm -rf /tmp/ansible

#Download java dependencies
RUN cd /usr/lib/stardust/pipeline/java && \
        mkdir -p maven && \
        JAVA_HOME=/usr/share/logstash/jdk mvn -Dmaven.repo.local=/usr/lib/stardust/pipeline/java/maven dependency:resolve &&\
        chown -R logstash:root maven


VOLUME /usr/share/logstash/pipeline_aggregate/
VOLUME /usr/share/logstash/pipeline_ingest/
VOLUME /usr/lib/stardust/pipeline/ruby
VOLUME /usr/share/logstash/config 
VOLUME /etc/stardust/pipeline/certificates

USER logstash

VOLUME /usr/share/logstash/config
