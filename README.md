# Stardust SNMP Pipline

## Overview
The SNMP pipeline processes data collected from network devices primarily using the SNMP protocol. Admittedly the “SNMP” portion of the name is a bit of a misnomer as the capabilities of the pipeline are capable of processing non-SNMP data as well such as RESTCONF, NETCONF (or anything that can be represented as JSON). The key capabilities of the pipeline are:

1. Rate Calculation 
2. Data Normalization
3. Metadata Enrichment

### Rate Calculation
Data that comes out of SNMP is often represented by counters that continuously increase. For example a router interface may have a traffic counter value of 10 billion meaning that it has seen 10 billion bytes since the interface first came-up. This number by itself is not particularly useful, but if you collect it at regular intervals (example every 30 seconds) you can measure changes in the counters between the current and previous measurement. This gives you a delta and you can then also divide by the time between measurements to get a rate. Using interface traffic again, this gives you bits moved in the last 30 second and also allows you to calculate a bits per second rate, both of which are valuable. These types of calculations add requirements to the pipeline to:

* **Maintain state of previous measurements** - We need to maintain internal state of previous measurements so the can be used in subsequent rate calculations

* **Maintain strict ordering of events** - If events are processed out of order then we will not be able to calculate a rate since the previous event may be processed before an event that comes after, making a rate calculation impossible. This is especially important when considering concurrency as well, since you don't want to unintentionally create race conditions that cause events to be processed out of order.

### Data Normalization
Collected data can vary across vendors, SNMP MIBs or many other vectors. The pipeline tries to resolve many of these differences to make the data easier to work with when it is later being queried. Some examples include:

* The same interface may have different identifiers in one MIB vs another. The pipeline tries to join data using the different identifiers into one record to with a normalized identifier, while also maintaining the individual identifiers in case they are useful at query time.
* Different vendors may have different names for the same data. The pipeline will normalize to a common name. 
* Achieving this normalization requires a fair amount of understanding of the meanings of various fields. The pipeline tries to generalize this as much as possible while still leaving hooks to handle specialized cases.

### Metadata Enrichment
The pipeline is responsible for tagging events with metadata related to the resource they represent. This can be different things like names for a resource, characteristics like speed/capacity or relationship to organizations to name a few. Example for sources of metadata include:

* Collected SNMP (or similar) events
* Internal inventory databases

A large part of the challenge is using the metadata to form relationships between different ingested data and is important to the data normalization process as well. The pipeline tries to generalize these lookups as well with hooks to add new sources easily.

## Data Model
The pipeline currently handles the following types of data:

* Router Interface Data
* Router Chassis
* Router Chassis Parts
* PDU Outlets
* Transponder Ports
* Transponder Channels

### Router Interfaces 
Perhaps the most heavily used data in the pipeline is the router interface data. We collect things like traffic, errors and discards for each interface. An “interface” can come in a few different forms depending on the vendor of the router. In general, there are physical interfaces (often called “ports”), which represent the hardware where connections made to routers and virtual interfaces that represent logical constructs associated with physical interfaces that are used in forwarding decisions made by the router. Virtual interfaces can come in many different flavors such as traditional VLANs, layer 3 VPNs and more. Perhaps the most complicated of the routers we have to deal with in this regard are the Nokias. Below is a diagram that attempts to explain the constructs Nokia uses to define ports and the virtualization that happens on top of them:

![Nokia SNMP Entities](/docs/diagrams/snmp_entity.png)

In Stardust we try to map all the metadata and data for the constructs that have one-to-one relationships into the same “interface” record in stardust. For the 1-to-many (or if there were many-to-many) we try to have separate records with pointers between records as needed. Example below for the Nokias where each colored box represents a single document when written to Elasticsearch:

![Nokia SNMP Entities](/docs/diagrams/snmp_entity_rels.png)

For Juniper routers, the mapping is much simpler as we generally just give each entry in the IF-MIB interface table its own entry and don’t have to worry about things like SAPs, etc. 

### Router Chassis
Router chassis data can be thought of as data related to the router as a whole (as opposed to a specific part or interface). This includes things like CPU and memory utilization.  The data model is pretty straight forward in that you have a physical router chassis and you have stats about that chassis.

### Router Chassis Parts
Router chassis’s have components beyond just individual interfaces for which data can be collected. This includes things like cards that hold multiple interfaces for which we want stats like temperature and other metrics. There is much less of this data than router interface data and usually just have the name of the router, the name of the component and the stats collected.

### PDU Outlets
Each router has one or more power distribution units (PDUs) attached to it. These PDUs have “outlets” or a close approximation where the router   Measuring this data allows us to measure the consumption of the network and allows us to do things like reconcile power billing information. Currently we have two flavors of PDU based on manufacturer:

Sentry - The Sentry PDU data is structured such that there is a device and outlet ID. 

Alpha - The Alpha manufactured PDUs are structured as a hierarchy of system, subsystem and bus. A bus  is a group of outlets, but it is the smallest unit for which we can get statistics.

### Transponder Ports and Channels
We currently collect data from the ESnet optical transponder. Each transponder has a set of ports and each port can be divided into a set of channels. ESnet runs what is called an open line system (OLS) where the “open” part means we can run transponders from different vendors. ESnet currently runs transponders manufactured by two vendors: Ciena and Infinera. The structure of the data is similar in the sense that both are divided into ports and channel, but some of the metrics you get back vary between each. They also both have the concept of client ports (ports that connect to routers) and line ports (ports the connect to other transponders) which also influence which stats are returned.

## Workflow
The workflow of the pipeline can be seen below:

![SNMP Pipeline Flowchart](/docs/diagrams/snmp_flowchart.png)

The pipeline is generalized such that it is primarily driven by two YAML config files: mappings.yaml and lookups.yaml. You are also free to add additional Logstash steps, but the idea is is that generally when you add a new MIB or similar that you update the YAML files since they have normalized many common operations.

 The first YAML file is **mappings.yaml** and it contains rules for what actions to take on fields from incoming events. There are currently four types of rules:

* meta_maps - This map takes a source field from the incoming events and gives details how to handle descriptive information (metadata) about a resource. This includes linking it to metric values (see value_maps), how to rename fields, data typing and any normalization functions (numeric calculations, regex, etc). This data will be cached in Redis and pulled out as relevant data arrives.

* value_maps - This map takes source fields from incoming events and gives details on how to process metric values they contain. This includes how to rename fields, data typing, whether or not details/rates need to be calculated, normalization, etc. This data will ultimately be stored in Elasticsearch.

* value_id - This is a set of instructions for building an identifier for data from value_maps. This identifier will be used in things like aggregation and ultimately generate the value of the meta.id field stored in Elasticsearch. It can be as simple as pulling a value from a field, but may also contain aa chain of operations in including performing an arbitrary number of Redis lookups against relationships defined in relation_maps.

* relation_maps - These contain rules for mapping data and metadata to each other when the relationship might not be direct. For example, it two sets of data have a different OID index but map to the same interface name, you can build a relation that maps each OID index to the correct name. These mappings are stored as a key/value pair in Redis. The relations defined are then referenced in sections likevalue_id and meta_maps to build the needed associations. They may also be used in the lookups.yaml file to pull in metadata for data. 

The second file is **lookups.yaml** which is organized by record type (e.g. interface, chassis, transponder_port, etc) and contains instructions for adding metadata to events. This usually consists of instructions for Redis lookup tables including how to build the lookup key and the name of the Redis hash set to query.  It is much smaller and simpler than mappings.yaml, but serves an important function in the final stages of building the record to be stored in Elasticsearch. 

## Pipeline Schematic
The organization of Kafka topics, Logstash processes and threading are done in a specific manner to maintain event ordering while still allowing parallel processing of events needed to reach desired pipeline throughput. The diagram below describes this best:

![SNMP Pipeline Architecture](/docs/diagrams/snmp_pipeline.png)

## Running Docker container
This repository can be customized and used to build a docker image of the basic pipeline. It uses ansible to generate settings based on variables you set in your environment. Basic instructions are below:

1. In the file `ansible/vars/dev-staging.yml` update the variables specific to your environment. Specifically update the passwords markes as CHANGEME, the kafka bootstrap servers and Elasticsearch hosts. 
2. Run the `update-configuration.yml` AAnsible playbook to bild your pipeline:
```
cd ansible
ansible-playbook -i inventory update-configuration.yml
```
3. Build and start the docker container:
```
docker-compose up --build -d
```

