#!/bin/bash

cat /usr/lib/stardust/tests/inputs/$1 | kafka-console-producer.sh --bootstrap-server 127.0.0.1:9092 --topic ${2:-stardust_snmp}
