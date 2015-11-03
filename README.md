# Ognitio: Cluster Configuration

This repository contains scripts and configurations used at Ognitio to
automate the deployment process of our clusters. As we run Apache Mesos
and a few of his frameworks for scheduling, we plan to continuously
share publicly related templates and scripts through this directory.

### Status

This project is undergoing heavy refactoring, hardening and testing
and isn't even considered alpha.

### Technology stack

We mainly rely on [Ansible](https://github.com/ansible/ansible) to
configure our VMs. 

The following list contains some of the projects that composes our
stack: 

- Consensus
    - [Apache ZooKeeper](https://zookeeper.apache.org/): Distributed systems coordination

- Resource management
    - [Apache Mesos](http://mesos.apache.org/)

- Scheduling (i.e. Mesos frameworks)
    - [Marathon](https://mesosphere.github.io/marathon/): Long running services
    - [Aurora](http://aurora.apache.org/): Long-running services and cron jobs
    - [Chronos](http://mesos.github.io/chronos/): Cron jobs
    - [Kafka](https://github.com/mesos/kafka): Apache Kafka on Apache Mesos
    - [Elasticsearch](https://github.com/mesos/elasticsearch): Elasticsearch on Apache Mesos

- Logging and metrics
    - Transport
        - [Telegraf](https://github.com/influxdb/telegraf): Plugin-driven server agent for reporting metrics
        - [Fluentd](http://www.fluentd.org/): Data collector
    - Storage
        - [InfluxDB](https://influxdb.com/): Distributed time series database
        - [Elasticsearch](https://www.elastic.co/)
    - Visualization
        - [Kibana](https://www.elastic.co/products/kibana)
        - [Grafana](http://grafana.org/)

- Container registry
    - [Distribution](https://github.com/docker/distribution): Docker toolset to pack, ship, store, and deliver content

- Service discovery and load balancing
    - [HAProxy](http://www.haproxy.org/): TCP/HTTP Load Balancer
    - [Mesos DNS](http://mesosphere.github.io/mesos-dns/): DNS-based service discovery for Mesos

- Application isolation
    - [Weave](http://weave.works/): Network of Docker containers

### Further work

- Authorization and authentication
- Secret files distribution
- Finer cloud providers deployment support (GCE, AWS, ...)
