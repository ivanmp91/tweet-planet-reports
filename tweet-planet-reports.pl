#!/usr/bin/env perl

use strict;
use warnings;
use LWP::UserAgent;
use XML::FeedPP;
use DBI;
use POSIX qw(strftime);
use Net::Twitter;
use Data::Dumper;

#################### VARIABLES #################
# URL to get the rss sources
my $url = "http://planetasysadmin.com/rss20.xml";
# Number of days with the report will work
my $days = 7;
# String with the tweet header before include the reports
my $tweet_header = "Contribuciones a planetasysadmin.com esta semana por cada blog";
# Max characters defined for a tweet
my $tweet_max_len = 140;
# 1 If we want to include the tweet header on each tweet, 0 only will be included on the first tweet
my $include_header = 1;
# If the message takes more than one tweet creates a conversation for the tweets generated
my $t_create_conversation = 1;
# Your twitter consumer key
my $t_consumer_key = "";
# Your twitter consumer secret
my $t_consumer_secret = "";
# Your twitter access token
my $t_access_token = "";
# Your twitter access token secret
my $t_access_token_secret = "";
###################### BODY #####################
# If the server is available and has a valid content type for a rss channel
if(&check_url($url)){
	my $time_range = &get_time_range;
	my $rss = &get_rss_posts($url,$time_range);
	my @blog_posts;
	# Order by the number of posts created by the blog and creates the tweet message
	foreach my $blog (sort {scalar @{$rss->{$b}} <=> scalar @{$rss->{$a}}} keys %$rss){
		my $posts = $rss->{$blog};
		my $str_out = $blog." => ".@$posts." posts";
		push @blog_posts,$str_out;
	}
	# Send to twitter the message for each blog with the blog name and the number of posts
	&tweet(\@blog_posts) if @blog_posts;
} else{
	print "$url bad content or connection timeout with the web server!\n";
}

#################### FUNCTIONS #####################

# Connects with database and database structure if not exists. Returns a DBI object.
sub db_connect{
	my $dbfile = "/var/cache/rss-frequency-tweet/data.db";
	my $dsn = "dbi:SQLite:dbname=$dbfile";
	my $dbh = DBI->connect($dsn, "", "", {
   		PrintError       => 0,
   		RaiseError       => 1,
		AutoCommit       => 1,
		FetchHashKeyName => 'NAME_lc',
	});
	die "Cannot connect with database $dbfile" unless defined $dbh;
	
	my $load_tables = <<'END_SQL';
		CREATE TABLE IF NOT EXISTS last_update (
			date TEXT
		)
END_SQL
	$dbh->do($load_tables);
	return $dbh;
}

# Check connection with the web server and check if is a valid content type. Returns 0 or 1.
sub check_url{
	my $url = shift;
        my $ua = new LWP::UserAgent;
        chomp($url);
        if($url !~/^http:\/\// && $url !~/^https:\/\//){
                $url="http://".$url;
        }
        my $request = new HTTP::Request('GET', $url);
        my $response = $ua->request($request);
        if ($response->is_success) {
                my $content = $response->content_type();
                if($content eq "text/xml" || $content eq "application/atom+xml"
                || $content eq "application/rdf+xml" || $content eq "application/rss+xml"
                || $content eq "application/xml" ){
                        return 1;
                }
		return 0;
        }
	return 0;
}

# Get rss sources given a url and a time range. Returns a hash with a key for each blog name
# that contains an array with all the posts of the blog
sub get_rss_posts{
        my ($url,$time_range) = @_;
        my $feed = XML::FeedPP->new($url);
        my $date;
	my $title;
	my $id_site;
        my %entries;
        $feed->normalize();
        foreach my $item ($feed->get_item){
                $date = $item->pubDate;
		$title = $item->title;
		$id_site = $title;
		# By default it's included in the title the name of the site
		# in the title separated with the character ':'
		# and the title of the post
		$id_site =~ s/:.*//;
                if($date ge $time_range->{start_date} && $date le $time_range->{end_date}){
			if(defined $entries{$id_site}){
                        	my $exist_entries = $entries{$id_site}; 
				push @$exist_entries, {"url"=>$item->link,"title"=>$title,"date"=>$date,"author"=>$item->author,"description"=>$item->author};
				$entries{$id_site} = $exist_entries;
			} else{
				$entries{$id_site} = [{"url"=>$item->link,"title"=>$title,"date"=>$date,"author"=>$item->author,"description"=>$item->author}];
			}
                }
        }
        return \%entries;
}

# Get the time range which the posts will be included on the rss reports. Retruns a hash with the start and end date on ISO8601 format.
sub get_time_range{
	my $tz = strftime("%z", localtime);
	my @time_now = localtime;
	my @time_past = localtime;
	# Deduct the number of days to get the posts
	$time_past[3]-= $days;
	my $end_date = strftime("%Y-%m-%dT%H:%M:%S", @time_now) . $tz . "\n";
	my $start_date = strftime("%Y-%m-%dT%H:%M:%S", @time_past) . $tz . "\n";
	my %time_range = (start_date=>$start_date,end_date=>$end_date);

	return \%time_range;
}

# Split the report message in different tweets and send to twitter
sub tweet{
	my $blog_posts = shift;
	my $msg_tweet = $tweet_header."\n";
	my $blog_posts_len = scalar@$blog_posts -1;
	my $status_id;
	foreach my $index (0..$blog_posts_len){
		if(length($msg_tweet.$blog_posts->[$index])>=$tweet_max_len){
				$status_id = &send_tweet($msg_tweet,$status_id);
			if($include_header && length($tweet_header)<=$tweet_max_len){
				$msg_tweet = $tweet_header."\n";
				$msg_tweet .= "$blog_posts->[$index]\n";
			}else{
				$msg_tweet = "$blog_posts->[$index]\n";
			}
		}else{
			$msg_tweet .= "$blog_posts->[$index]\n";
		}
	}
	&send_tweet($msg_tweet,$status_id);
}

# Send tweet to twitter
sub send_tweet{
	my ($tweet, $status_id) = @_;
	my $status;
	print "DEBUG: Send tweet with this content:\n";
	print $tweet;
	my $nt = Net::Twitter->new(traits => ['API::RESTv1_1'], 
		consumer_key=>$t_consumer_key, consumer_secret=>$t_consumer_secret, 
		access_token=>$t_access_token, access_token_secret=>$t_access_token_secret,ssl => 1); 
	if(defined $status_id && $t_create_conversation){
		$status = $nt->update({ status => $tweet, in_reply_to_status_id => $status_id });
	} else{
		$status = $nt->update({ status => $tweet});
	}
	return $status->{id};
}
