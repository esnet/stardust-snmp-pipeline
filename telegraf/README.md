# Example SNMP Collector

### Overview

This is an included example SNMP collector based on telegraf. It collects common counter and metadata from interfaces on the configured routers via the standard ifTable and ifXTable and formulates it in such a way that the Stardust SNMP pipeline expects. It is designed to be a drop in capable collector for this project with minimal configuration. While Stardust can collect significantly more types of data, this serves as an example for a common use case.

### Configuration

The telegraf container reads its configuration from the telegraf.conf file here as well as any .conf files in the telegraf.d directory. This configuration is read when the container is started up, so any changes made will require a restart of the container.

The only file that should require edits is the `01-snmp-inputs.conf` file to fill out the agents and community string information. Multiple agents may be specified inside of one file. If you want to tweak what exactly is being collected you may adjust the SNMP paths in here.

### Filtering What Interfaces Are Collected
The `tagpass` section may be used to limit what interfaces are sent to the pipeline - this may be useful for collecting only known interesting links. Other telegraf filtering capabilities may be implemented here but are outside the scope of this document. 

Important - inside of a given SNMP section the `tagpass` settings will apply to all devices. If you have a complex setup where you only want interface 5 on router A and only interface 7 on router B, you should only put router A and its tagpass settings in `01-snmp-inputs.conf` and then copy it to `02-snmp-inputs.conf` and put router B's settings in there.

### Running the Container
This container will be started as a part of a regular `docker compose up` or may be controlled individually if needed. It expects the rest of the stack to be running. All of the normal log viewing, container status, etc apply here as well.