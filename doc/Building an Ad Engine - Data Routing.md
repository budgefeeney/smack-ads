# Building an Ad Engine: Data Routing

This is part of a multipart tutorial on how to build an ad-engine, whose parts are

1. [How to store data using Cassandra](tut-cassandra)
2. **Routing data using Kafka with Cassandra**
3. [Creating click-optimisation policies using Spark](tut-spark)
4. [Creating click-through reports using ElasticSearch](tut-elastic)

This is the second part. 

We will focus on how to use Kafka and Kafka streaming to take a sequence of impressons and clicks from our producing ad-server and construct appropriate records to be persisted in our Cassandra data-store.

## What is Kafka

Kafka is, like Cassandra and HDFS, a distributed data-store.

In Kafka, a collection of records is known as *topic*, analoguous to a HDFS file or a Cassandra table. These are broken down in chunks, known as *partitions*, analougous to HDFS blocks or Cassandra partitions. Like HDFS and Cassandra, partitions are replicated to several machines in a cluster for resiliency: even if one or two machines die, the data will still be available. Consequently, and also like HDFS and Cassandra, increasing topic-size can be handled simply by adding more machines. The software managing all this is the Kafka broker, which runs on all the machines where data is stored, like HDFS and Cassandra.

While HDFS, and to a less extent Cassandra, are designed for the long-term storage of data, Kafka is more of a temporary warehouse where date is stored while it is being routed elsewhere. Data for a topic is fed by a producer, and consumed by several consumers[^consumer-group]. Using Kafka streaming, data fed by producers into one topic can be used to create additional topics for consumption.


[^consumer-group]: Kafka by default gives exactly one copy of a piece of data to all listening consumers. As such it acts like a publish-subscribe system, broadcasting data to interested parties. However as well as consumers, "consumer groups" can also be registered. In this case each listening consumer, and exactly one consumer in each listening group, will get a copy. In this case Kafka acts more like a message queue, where consumers race to individually pick data off the queue as soon as they're ready..

Once all registered consumers have consumed a record from a topic, and a configurable time-limit has elapsed, that record is automatically deleted. This waiting period allows a consumer to make a second attempt to fetch records in case it encountered an error (on its side) the first time around. Kafka provides unique identifiers, called *offsets* to help consumers keep track of what they've read.

There are several [tutorials on setting up Kafka](kafka-install-tut) ([and here](kafka-install-tut-2)), and I'll defer to them. I presume that at this point you have both a Cassandra database and Kafka broker up and running. An easier route by far is just to use Docker with a pre-configured environment you can talk to, such as this [Cassandra, Kafka and Spark Docker image](smack-docker)

## A Simple Impression Workflow




## Using Kafka Streaming to Create a Summary Impression




## Using Kafka to Automatically Join Clicks with Impressions





[cassandra-hash-of-hashes]:http://fixme
[tut-cassandra]:http://fixme
[tut-kafka]:http://fixme
[tut-spark]:http://fixme
[tut-elastic]:http://fixme
[kafka-install-tut]:https://dtflaneur.wordpress.com/2015/10/05/installing-kafka-on-mac-osx/
[kafka-install-tut-2]:https://www.coshx.com/blog/2016/10/20/a-practical-guide-to-kafka1/
[smack-docker]:http://fixme