CREATE KEYSPACE IF NOT EXISTS
	adengine
WITH
	REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': 1 };


CREATE TABLE IF NOT EXISTS adengine.impression (
	advertiser_id  UUID,
	campaign_id    UUID,
	year           INT,
	day_of_year    INT,
	bucket_id      INT,
	impression_ts  TIMESTAMP,
	impression_id  UUID,
	ad_id          UUID,
	user_id        UUID,
	user_ip        TEXT,
	user_data      FROZEN<MAP<TEXT,TEXT>>,
	
	PRIMARY KEY (
		(advertiser_id, campaign_id, year, day_of_year, bucket_id),
		impression_ts, impression_id
	)
)
WITH
	CLUSTERING ORDER BY (impression_ts DESC)
	AND gc_grace_seconds = 23050 //  six hours
	AND compaction= {
		'class':'DateTieredCompactionStrategy' };
//		'compaction_window_unit': 'HOURS',
//		'compaction_window_size': '12',
//	};



CREATE TABLE IF NOT EXISTS adengine.click (
	advertiser_id  UUID,
	campaign_id    UUID,
	bucket_id      INT,
	impression_ts  TIMESTAMP,
	impression_id  UUID,
	PRIMARY KEY (
		(advertiser_id, campaign_id, bucket_id),
		impression_ts, impression_id
	)
)
WITH
	CLUSTERING ORDER BY (impression_ts DESC)
	AND gc_grace_seconds = 23050 // six hours
	AND compaction= {
		'class':'DateTieredCompactionStrategy' };
//		'compaction_window_unit': 'HOURS',
//		'compaction_window_size': '12',
//	};




CREATE MATERIALIZED VIEW adengine.impression_summary
AS
	SELECT
		advertiser_id,
		campaign_id,
		bucket_id,
		impression_ts,
		impression_id,
		ad_id
	FROM
		adengine.impression
	WHERE
		    advertiser_id IS NOT NULL
		AND campaign_id   IS NOT NULL
		AND bucket_id     IS NOT NULL
		AND year          IS NOT NULL
		AND day_of_year   IS NOT NULL
		AND impression_ts IS NOT NULL
		AND impression_id IS NOT NULL
	 
	 PRIMARY KEY (
        (advertiser_id, campaign_id, bucket_id),
         year, day_of_year, impression_ts, impression_id
   )
WITH
    CLUSTERING ORDER BY (year DESC, day_of_year DESC, impression_ts DESC)
		AND gc_grace_seconds = 23050 // six hours
    AND compaction= {
			'class':'DateTieredCompactionStrategy' };
//			'compaction_window_unit': 'HOURS',
//			'compaction_window_size': '12',
//    };
