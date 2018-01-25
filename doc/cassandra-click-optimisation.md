# Building an Ad Engine: Data Storage

This is part of a multipart tutorial on how to build an ad-engine, whose parts are

1. **How to store data using Cassandra**
2. [Moving data using Kafka and Cassandra](tut-kafka)
3. [Creating click-optimisation policies using Spark](tut-spark)
4. [Creating click-through reports using ElasticSearch](tut-elastic)

This is the first part. 

We will focus on how best to use Cassandra to store the necessary information that our ad-serving platform will be generating, with a particular emphasis on Cassandra's support for time-series optimisation.

## Schema Design Considerations for Cassandra

Cassandra is our database of choice because it

 1. Has extremely fast writes
 2. Stores copies of data ni different machines for redundancy and so trivially survives a single machine dying
 3. Automatically distributes data across machines, particularly as new machines are added, and so write performance is easily improved by adding new machines
 4. Automatically sorts data by a certain key on writes, optimising `order by` queries, and so performs particularly well for time-series data.

Whie Cassandra is distributed (aka *partition-tolerant*) and provides guaranteed *availability*, it achieves this at the cost of being only eventually *consistent*; the most recent read may not reflect what was added in the most recent write, at least not for a while. There are ways around this which we'll discuss later.

#### How Cassandra works

When using any database, the two considerations are: firstly, how does the database store data; and secondly, what are the queries that will be executed.

Cassandra stores its database tables as a `HashMap` of keys to blocks of rows called "partitions". Each partition is itself a `SortedMap` of keys to individual rows. Each row is a `Map` of column names and values[^map-column-family], Note that not every column in the table schema needs to be explicitly stored. 

Cassandra's `HashMap` distributes its key-values pairs -- the partitions -- across machines, so it's important that it is *balanced*. I've written more about [Cassandra's data-model here](cassandra-explanation).

The primary key for a cassandra table has two parts, the mandatory *partition key*, which is the key of the `HashMap`, which distributes data; and the optional *cluster key*, which is the key in the `SortedMap` which controls how data is sorted. Both can consist of multiple columns

So our task is to

1. Pick a partition key that balances out data writes across clusters: this may need an additional salt in order to balance the table
2. Pick a key that sorts data on write to make reads more efficient.

## Ad-Serving Data

Our model is as follows:

1. An advertiser runs several campaigns
2. Each campaign has several individual ads: e.g. a travel-agent might run a book-your-summer-holiday campaign with ads which involve: (1) either couples or families; (2) beaches or cities and (3) for affordable or expensive destinations; which together gives eight variations.

Each ad is shown

1. At a particular time
2. To a particular user
3. Who may have other data associated with them that we can glean from them and use for targeting.

Ads might be clicked, but a click might arrive five minutes after an ad is shown: an ad display is called an *impression*.

So in a simple case we might have two tables: `impression` and `click`.

But we're getting ahead of ourselves: before we commit to a schema-design, we need to consider what our queries are going to be.

## Ad-Serving Queries

In an ad-serving platform there are really just three core workflows

<dl>
<dt>Bulk Query</dt>
<dd>
Exhaustively iterate through *all* the data for a campaign (or possibly all campaigns) to train an ad-targetting model.
</dd>
<dt>Summary Query</dt>
<dd>
Do a simple query to get the number of impressions and clicks for a particular time-period and campaign
</dd>
<dt>Report Query</dt>
<dd>
Generate simple reports about what kind of users clicked on what kind of data for a particular time period and campaign. This is similar to bulk, but using fewer fields.
</dd>
</dl>

One thing to note is exhaustive user-data is only really required for the bulk, and to a lesser extent, the report queries. 

Another thing to note is that we will almost always want statistics for the most recent time-period, and will want to tune our compaction-strategies[^compaction] to reflect that.

[^compaction]: Cassandra stores a table's data by appending updates, which might only affect a subset of columns for each row, to a list of updates. Even deletions are implemented by appending a deletion marker to the list of updates. Compaction is the process of regularly compacting these list of updates into ground truth to expedite read performance and minimise on-disk storage. By default compaction is triggered by a partition, i.e. a block of rows, exceeding a certain size, but it can also be triggered by a partition being older than a given amount of time.

For the purposes of *this part* of the tutorial, we'll assume there's no way to safely buffer up impressions while we wait to see if we've got a click or not, which will require storing separate *impression* and *click* tables. We will additionally store an *impression_summary* table with slightly fewer columns to expedite reads (Cassandra writes are so cheap it's better to write more to read faster).

## Our Schema

Here's the impression table. We'll go through it bit by bit.

~~~sql
CREATE TABLE IF NOT EXISTS impression (
	advertiser_id  UUID,
	campaign_id    UUID,
	year           INT,
	day_of_year    INT,
	bucket_id      INT,
	timestamp      TIMESTAMP,
	impression_id  UUID,
	ad_id          UUID,
	user_id        UUID,
	user_ip        TEXT,
	user_data      FROZEN<MAP<TEXT,TEXT>>,
	
	PRIMARY KEY (
		(advertiser_id, campaign_id, year, day_of_year, bucket_id),
		timestamp, impression_id
	)
)
WITH 
	CLUSTERING ORDER BY (timestamp DESC)
	AND compaction= {
    'compaction_window_unit': 'HOURS',
    'compaction_window_size': '12',
    'class':'TimeWindowCompactionStrategy'
    };
   AND gc_grace_seconds = 23050 -- six hours
~~~

#### Partition Key

The partition key is the first element of a composite primary key, which can itself be a composite key. In our case its a composite of `advertiser_id`, `campaign_id`, `year`, `day_of_year` and `bucket_id`.

If the partition key were just `(advertiser_id, campaign_id)`, the entirety of all impressions for a single campaign would be stored on a single machine, which could overwhelm it.

This is why we add some temporal information, `year, day_of_year`. Now data is spread out across our cluster. A disadvantage of this approach is that if we want a month's impressions for a single campaign, we'll need to perform 31 separate queries.

The last item is the `bucket_id`. 

This is a last-resort cluster-balancing tool. Say there are a handful of ad-campaigns that have much much larger numbers of impressions-per-day than average. Without a bucket in the partition-key, such campaigns will create a "hot-spot", a single machine that is being overwhelmed by far more traffic than it is able for. 

To balance this out we can set up a bucket-count for each campaign, usually set to 1, but for campaigns that we predict will be n-times larger than average, set to `n`. Our business-logic code will then generate a `bucket_id` in the range `1...n` for every individual ad-impression, so that excessive writes can be distributed.

Ultimately this is a matter of *scale*, if we're expecting millions of impressions each day, then this makes sense. If we're expecting 100,000 impressions a day, perhaps we could use the week as a temporal partition key element and forget about bucketing. 

As a rule of thumb, a partition-key should identify no more than 100MB of data.

#### Cluster Key and Cluster-Key Ordering

The next element in our primary key is the cluster key is a composite key of `timestamp` and `impression_id`. This determines how data is sorted on each partition.

A neat trick is the fact that by specifying that the `CLUSTER ORDERING` is `DESC`ending on `timestamp`, the data will be sorted accordingly. Henceif we just do a `LIMIT 10` on a particular query, we will get the *most recent* impressions in that partition, e.g.

~~~sql
-- Fetches the most recent ten impressions 
-- in the last 24 hours
SELECT
	impression_id,
	user_id,
	ad_id
FROM
	impressions
WHERE
	advertiser_id = 'xxxx-holi-days'
	AND campaign_id = 'xxx-winter-break'
	AND year=2018
	AND (day_of_year = 230 OR day_of_year = 231),
	AND timestamp > currentTimeStamp() - 1d
LIMIT
	10
~~~

Note we didn't need to specify an `ORDER BY` clause.

Note also that we had to specify `day_of_year` manually: currently Cassandra has very little support for functions on dates.

As regards `impression_id`, its necessary to ensure that primary keys identify unique rows, but otherwise it has little bearing on this.

> **On the Dangers of IN clauses**
> 
> The natural SQL approach to getting information for the last 31 days is to specify the indices of the last 31 `day_of_year` values in a single `IN` clause. 
>
> This is not a good idea.
>
> When executing a query, a single node takes responsibility for scattering out the subqueries to the individual nodes, and then gathering up all the results in one place, before sending them back. This is called the coordination node. If the number of subqueries is too large (e.g. 31 values in an `IN` clause) the particular coordinator-node will begin to slow down and struggle as data accumulates.
>
> A better approach is to generate and execute 31 independent queries concurrently, and accumulate the results in the client side as [illustrated here](multi-query). These will then be scattered out to the 31 nodes which are able to give the fastest answer. 

#### The Compaction Strategy

Compaction is the process by which many SSTables full of updates get reduced down to a single SSTable full of values.

Normally this is triggered by size, but since we know we're interested in limiting our queries by *time* instead of *row count*, we should compact by time instead.

The `TimeWindowsCompactionStrategy` groups uncompacted SSTables into a bucket, and a after set window of time expires, applies the usual `SizeTieredCompactionStrategy` to them, resulting in at least one compacted SSTable per time-window.

In general, it's advised not to have more than 50 SSTables per partition. If we expect a campaign to typically last no more than four weeks, we'll want a table for every half a day, hence the 12 hour window.

This means we will cease compacting data after 12 hours have passed.

Note that a side-effect is that table repairs fragment SSTables, and these fragments -- if they exist outside the window -- will never be re-compacted together again. This is a trade-off: we accept a certain amount of fragmentation to avoid excessive writes (aka *write amplification*)

Given that, it should be clear that time-windowed compaction is *not* suitable for mutable tables that see a lot of updates. In our case, our `impression` table is an immutable store of time-series data, and so is the ideal use-case.

This [explanation of TimeWindowedCompactionStrategy](http://thelastpickle.com/blog/2016/12/08/TWCS-part1.html) has lots more detail. 

One further aspect of note is `gc_grace_seconds`. This is how long Cassandra keeps a record-deletion marker, known as a *tombstone*, in the database table, before actively removing it. Tombstones exist so that if a node A with a replicated copy node B's table was down during the deletion, when it arises and the cluster does a repair, the tombstone will be synced over letting node A also know it has to delete a record. However if the tombstone and record has been deleted from node B while A was down then the repair will observe that B is missing a records from A, and *copy it back* to A from B, resurrecting it.

In general you want tombstones removed before compaction, so `gc_grace_seconds` should be smaller than the bucket size, but still as large as possible to ensure deletions are accurately propagated. In our case, we don't intend on deleting or updating records, so it can be very large. In cases with a lot of updates and deletions, you may have to reduce the time to ensure the number of tombstones doesn't grow too large.

#### The Data Itself, and a Map

The data itself is pretty small, just an impression_id, so we can uniquely identify the impression[^impression-id], a user's unique ID and IP address, and a map of user-data.

To which the obvious question is, why not have separate columns for the data?

The answer is we want this model to be flexible, to handle the presence and absence of user data-fields between versions of our application, and between different campaigns within the same version (some campaigns may pass additional information with the request).

Since every Cassandra table's row is ultimately just a Map of column-names to column-values, and since `MAP`s are just implemented by adding more columns to that built-in map, the cost is low.


Altering maps however [generates large tombstone entries](http://www.sestevez.com/on-cassandra-collections-updates-and-tombstones/), and so in that case you may wish to consider alternatives. Further any query that involves reading a `MAP` column will obviously read *all* of the entries in that map. If you frequently find yourself reading a subset of a map's values, you can expedite performance by pulling those map entries out into named columns, or else by splitting the map up (e.g. `user_profile_data`, `user_retargeting_data`, `user_geo_data`).


In the case of our Bulk Query example, we expect to always read in the entirety of this `MAP` on any read. As an optimization, to limit the serialization/deserialization overhead, we store the map as `FROZEN`. This is a more efficient way of storing data on disk, at the cost of no longer supporting incremental updates.

Other practitioners have suggested just using [a `TEXT` blob storing XSV data](used-cassandra-suprise-xsv). In general careful attention, benchmarking, and [examination of the documentation](cassandra-collections-docs) is required for Cassandra collection types, particularly if you expect to mutate data after insert.

[^impression-id]: Note that because it's neither a part of the key nor indexed, we can't use `impression_id` in a `WHERE` clause of a `SELECT` statement. We would either need to add an index (a terrible idea, discussed later) or create a duplicate table where `impression_id` is a part of the primary key

#### What we didn't do

Every individual value in Cassandra can be configured to auto-destruct after a certain amount of time, its *time to live* (TTL). 

If we chose only to provide data for 30 days, we could add an extra `WITH` clause to our table's `CREATE` statement saying

~~~sql
WITH 
	-- etc., etc., 
   AND default_time_to_live = 30 * 86400
~~~

This would then require us to alter out compaction window and `gc_grace_seconds` parameters accordingly.

However in practical terms its usually necessary to retain data for years, just for accounting and auditing purposes, so we won't be doing that.

### The Click Table

The clicks table is

~~~sql
CREATE TABLE IF NOT EXISTS click (
	advertiser_id  UUID,
	campaign_id    UUID,
	bucket_id      INT,
	timestamp      TIMESTAMP,
	impression_id  UUID,
	PRIMARY KEY (
		(advertiser_id, campaign_id, bucket_id)
		timestamp, impression_id
	)
)
WITH 
	CLUSTERING ORDER BY (timestamp DESC)
	AND compaction= {
    'compaction_window_unit': 'HOURS',
    'compaction_window_size': '12',
    'class':'TimeWindowCompactionStrategy'
    };
   AND gc_grace_seconds = 23050 -- six hours
~~~

With this table our client code has to do two queries: the first to get an exhaustive list of all impressions which had clicks, and a second to get a list of all impressions, and then manually do the join in client-side code.

Note that as Cassandra is not consistent, only eventually consistent, these two tables may not perfectly align unless one limits the time to the recent past (e.g. no more recent than a five minutes ago) so there's a chance for writes to replicate.

In this case we take advantage of the fact that the number of clicks is tiny relative to impressions (being less than 0.1% of total), and so can be stored in client-side memory.

While we could use `impression_id` as a unique primary key, in practice we'll just want all clicks for a particular campaign and time-period, so we use a similar exact key structure as our impression table. We store all clicks for a campaign on a single machine (or however many are specified by buckets) since given the small size of the table, and small number of clicks, we don't need to partition as agressively to stay within the 100MB limit.

## Materialized Views

At this point we have everything we need, pretty much, for our bulk-query problem. The same table structure is presumably good for reporting. However for simple clickthrough analytics -- what were the click-through rates for each ad in this time-frame -- the impression table is arguably oversized for what we want.

We could instead store an `impression_summary` table with much less data. One approach to this, which we'll discuss later, is to have our Kafka data-pipeline dynamically create two output rows for import by Cassandra from every one row exported by our application. The other approach, is to have Cassandra do this itself.

A *materialized view* in Cassandra is a table which is stored on disk, and automatically updated by Cassandra every time a base table is updated. Unlike in relational databases, where materialized views can be used to maintain tables of aggregates for OLAP-style queries, in Cassandra, every row in the base table must correspond exactly to a row in the view, such that they both have the same row-count.


So why have materialized views? Three reasons:

1. You want the same data with a different key structure (particularly at partition-level) for a set of queries that involve different fields in their `WHERE` clause
2. You want the same data with fewer columns for a set of queries accessing different (or a subset of) columns in their `SELECT` clause
3. A combination of (1) and (2)

In our case we could have a `user_data_by_impression` table that would return the `user_data` for a particular `impression_id`, say if we wanted to examine the population of people clicking on ads.

Or we could have an `impression_summary` table which had just a subset of the fields in the `impression` table for rapid querying of simple values. We'll discuss the latter here.

The code to create our materialized view is:

~~~sql
CREATE MATERIALIZED VIEW
	impressions_summary
AS
	SELECT
		advertiser_id UUID,
		campaign_id   UUID,
		bucket_id     INT,
		timestamp     TIMESTAMP,
		impression_id UUID
		ad_id         UUID	
	FROM
		impression
	WHERE
		    advertiser_id IS NOT NULL
		AND campaign_id   IS NOT NULL
		AND year          IS NOT NULL
		AND day_of_year   IS NOT NULL
		AND bucket_id     IS NOT NULL
		AND timestamp     IS NOT NULL
	 
	 PRIMARY KEY (
        (advertiser_id, campaign_id, bucket_id),
        timestamp, impression_id
    )
)
WITH 
    CLUSTERING ORDER BY (timestamp DESC)
    AND compaction= {
    'compaction_window_unit': 'HOURS',
    'compaction_window_size': '12',
    'class':'TimeWindowCompactionStrategy'
    };
   AND gc_grace_seconds = 23050 -- six hours
~~~

As with the clicks data, we're using the fact that we're storing less data to 


Note that this does not come for free. With a materialized view, every insert into the base table will *first generate a read, and secondly a write*. This read-before-write pattern can slow down inserts, particularly as tables grow, which is why it may be better for your data-pipeline to generate these additional views instead of Cassandra itself.

## Conclusion

This is where we'll leave the example for now. 

We have created three tables: one recording full ad-impression data for training models and doing complex reports; one recording basic ad-impression data for simple clickthrough-rate reports; and a table for recording which ad-impressions generated clicks.

The main deficiency of this model is that we have to do joins in client code. Tools like SparkQL can simplify this, but in an ideal world, our data-pipeline would perform the denormalisation step of appending a `clicked` field to our `impression` and `impression_summary` tables before we wrote into our Cassandra store.

Left outer joins are also susceptible to inconsistencies in eventually consistent databases. One way to get around this is to just wait a set time period (e.g. 15 mins) and presume that all changes will have synced by that time. Another is do have a 24 hour delay and force a full cluster sync using the `nodetool repair -dc-par -inc` command at quiet periods.

In the next part we'll discuss how to configure just such a data pipeline using Kafka.



[^map-column-family]: In fact, a row in Cassandra is a list of column families (i.e. `Map<ColumnName, ValueEnvelope>`), where the value envelope wraps a value alongside a timestamp and other information. Writes are stored by appending a column-family (map of named row-values) onto a that list. Reads are achieved by going back into that list till the most recent values for all columns are retrieved.

[cassandra-hash-of-hashes]:http://fixme
[tut-kafka]:http://fixme
[tut-spark]:http://fixme
[tut-elastic]:http://fixme
[cassandra-explanation]:http://fixme
[multi-query]:https://lostechies.com/ryansvihla/2014/09/22/cassandra-query-patterns-not-using-the-in-query-for-multiple-partitions/
[used-cassandra-suprise-xsv]:https://blog.parse.ly/post/1928/cass/
[cassandra-collections-docs]:https://docs.datastax.com/en/cql/3.3/cql/cql_using/useCollections.html

