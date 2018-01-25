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



