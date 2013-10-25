require 'findit-support'
require 'logger'
require 'csv'

class NilClass
  def empty?
    true
  end
end

module VoteATX
  class Loader

    DEFAULT_COL_NAMES = {
      :SITE_NAME => "Name",
      :PCT => "Pct",
      :COMBINED_PCTS => "Combined Pcts.",
      :LOCATION_ADDRESS => "Address",
      :LOCATION_CITY => "City",
      :LOCATION_ZIP => "Zipcode",
      :LOCATION_LONGITUDE => "Longitude",
      :LOCATION_LATITUDE => "Latitude",
      :SCHEDULE_CODE => "Hours",
      :SCHEDULE_DATE => "Date",
      :SCHEDULE_TIME_OPENS => "Start Time",
      :SCHEDULE_TIME_CLOSES => "End Time",
    }

    attr_reader :dbname
    attr_reader :debug
    attr_reader :log
    attr_reader :db
    attr_accessor :col_name
    attr_accessor :valid_lng_range, :valid_lat_range, :valid_zip_regexp
    attr_accessor :election_description, :election_info

    def initialize(dbname, options = {})
      @dbname = dbname
      @debug = options.has_key?(:debug) ? options.delete(:debug) : false
      @log = options.delete(:log) || Logger.new($stderr)
      @log.level = (@debug ? Logger::DEBUG : Logger::INFO)

      raise "database \"#{@dbname}\" file does not exist" unless File.exist?(@dbname)
      @db = Sequel.spatialite(@dbname)
      @db.logger = @log
      @db.sql_log_level = :debug

      @col_name = DEFAULT_COL_NAMES.dup
      @valid_lng_range = -180 .. 180
      @valid_lat_range = -180 .. 180
      @valid_zip_regexp = /^78[67]\d\d$/

      @log.info("loading database \"#{@dbname}\" ...")
    end

    def cleanup_row(row)
      row.each {|k,v| row[k] = v.cleanup}

      # Convert "Combined @ 109 Parmer Lane Elementary School" -> "Parmer Lane Elementary School"
      row[@col_name[:SITE_NAME]].sub!(/^Combined\s+@\s+\d+\s+/, "")
    end

    def ensure_not_empty(row, *cols)
      cols.each do |col|
        raise "required column \"#{col}\" not defined: #{row}" if row[col].empty?
      end
    end

    # Extract date as [mm,dd,yyyy] from specified col, in form "MM/DD/YYYY"
    def get_date(row, col)
      ensure_not_empty(row, col)
      m = row[col].match(%r[^(\d\d)/(\d{1,2})/(\d\d\d\d)$])
      raise "bad #{col} value \"#{row[col]}\": #{row}" unless m && m.length-1 == 3
      m.captures.map {|s| s.to_i}
    end

    # Extract time as [hh,mm] from specified col, in form "HH:MM"
    def get_time(row, col)
      ensure_not_empty(row, col)
      m = row[col].match(%r[^(\d{1,2}):(\d\d)$])
      raise "bad #{col} value \"#{row[col]}\": #{row}" unless m && m.length-1 == 2
      m.captures.map {|s| s.to_i}
    end

    # Produce (start_time .. end_time) range from info in database record
    def get_datetimes(row)
      mm, dd, yyyy = get_date(row, @col_name[:SCHEDULE_DATE])
      start_hh, start_mm = get_time(row, @col_name[:SCHEDULE_TIME_OPENS])
      end_hh, end_mm = get_time(row, @col_name[:SCHEDULE_TIME_CLOSES])
      Time.local(yyyy, mm, dd, start_hh, start_mm) .. Time.local(yyyy, mm, dd, end_hh, end_mm)
    end

    # Determine if an open..close Time range is the indicator for a closed day (0:00 to 0:00).
    def is_closed_today(h)
      h.first == h.last && h.first.hour == 0 && h.first.min == 0
    end

    # Given a list of open..close Time ranges, produce a display as a list of String values.
    def format_schedule(hours)
      sched = []
      curr = nil
      hours.each do |h|

        date = format_date(h.first)
        hours = if is_closed_today(h)
            "closed"
          else
            format_time(h.first) + " - " + format_time(h.last)
          end

        if curr
          if curr[:hours] == hours
            curr[:date_last] = date
            curr[:formatted] = curr[:date_first] + " - " + curr[:date_last] + ": " + curr[:hours]
            next
          end
          sched << curr[:formatted]
        end

        curr = {
          :date_first => date,
          :date_last => date,
          :hours => hours,
          :formatted => date + ": " + hours,
        }

      end
      sched << curr[:formatted] if curr
      sched
    end

    # Given an open..close Time range, format the hours that day as a String
    def format_schedule_line(h)
      if is_closed_today(h)
        format_date(h.first) + ": closed"
      else
        format_date(h.first) + ": " + format_time(h.first) + " - " + format_time(h.last)
      end
    end

    # Format the date portion of a Time value to a String
    def format_date(t)
      t.strftime("%a, %b %-d")
    end

    # Format the time portion of a Time value to a String
    def format_time(t)
      t.strftime("%-l:%M%P").sub(/:00([ap]m)/, "\\1").sub(/12am/, 'midnight').sub(/12pm/, 'noon')
    end

    # Initialize all the tables
    def create_tables
      @log.info("create_tables: creating database tables ...")

      @log.debug("create_tables: creating table \"election_defs\" ...")
      @db.create_table :election_defs do
        String :name, :index => true, :size => 16, :null => false
        Text :value
      end
      @db[:election_defs] << {:name => "ELECTION_DESCRIPTION", :value => @election_description}
      @db[:election_defs] << {:name => "ELECTION_INFO", :value => @election_info}

      @log.debug("create_tables: creating table \"voting_locations\" ...")
      @db.create_table :voting_locations do
        primary_key :id
        String :name, :size => 20, :null => false
        String :street, :size => 40, :null => false
        String :city, :size => 20, :null => false
        String :state, :size=> 2, :null => false
        String :zip, :size => 10, :null => false
        Text :formatted, :null => false
      end
      rc = @db.get{AddGeometryColumn('voting_locations', 'geometry', 4326, 'POINT', 'XY')}
      raise "AddGeometryColumn failed (rc=#{rc})" unless rc == 1
      rc = @db.get{CreateSpatialIndex('voting_locations', 'geometry')}
      raise "CreateSpatialIndex failed (rc=#{rc})" unless rc == 1

      @log.debug("create_tables: creating table \"voting_schedules\" ...")
      @db.create_table :voting_schedules do
        primary_key :id
        Text :formatted, :null => false
      end

      @log.debug("create_tables: creating table \"voting_schedule_entries\" ...")
      @db.create_table :voting_schedule_entries do
        primary_key :id
        foreign_key :schedule_id, :voting_schedules, :null => false
        DateTime :opens, :null => false, :index => true
        DateTime :closes, :null => false, :index => true
      end

      @log.debug("create_tables: creating table \"voting_places\" ...")
      @db.create_table :voting_places do
        primary_key :id
        String :place_type, :index => true, :size => 16, :null => false
        String :title, :size => 80, :null => false
        Integer :precinct, :unique => true, :null => true
        foreign_key :location_id, :voting_locations, :null => false
        foreign_key :schedule_id, :voting_schedules, :null => false
        Text :notes
      end
    end


    # Create an entry in the "voting_locations" table for this location, return row id.
    #
    # If the location already exists in the database, will return row id for existing row.
    #
    # The "values" list must define: "Name", "Address", "City", "Zipcode", "Longitude", "Latitude".
    #
    def make_location(values)
      ensure_not_empty(values,
        @col_name[:SITE_NAME],
        @col_name[:LOCATION_ADDRESS],
        @col_name[:LOCATION_CITY],
        @col_name[:LOCATION_ZIP],
        @col_name[:LOCATION_LONGITUDE],
        @col_name[:LOCATION_LATITUDE])

      lng = values[@col_name[:LOCATION_LONGITUDE]].to_f
      raise "longitude \"#{lng}\" outside of expected range (#{@valid_lng_range}): #{values}" unless @valid_lng_range.include?(lng)

      lat = values[@col_name[:LOCATION_LATITUDE]].to_f
      raise "latitude \"#{lat}\" outside of expected range (#{@valid_lat_range}): #{values}" unless @valid_lat_range.include?(lat)

      zip = values[@col_name[:LOCATION_ZIP]]
      raise "bad zip value \"Zipcode\": #{zip}" unless zip =~ @valid_zip_regexp

      rec = {
        :name => values[@col_name[:SITE_NAME]],
        :street => values[@col_name[:LOCATION_ADDRESS]],
        :city => values[@col_name[:LOCATION_CITY]],
        :state => "TX",
        :zip => zip,
        :geometry => Sequel.function(:MakePoint, lng, lat, 4326),
      }

      rec[:formatted] = rec[:name] + "\n" \
        + rec[:street] + "\n" \
        + rec[:city] + ", " + rec[:state] + " " + rec[:zip]

      loc = @db[:voting_locations] \
        .filter{ST_Equals(:geometry, MakePoint(lng, lat, 4326))} \
        .first

      if loc
        [:name, :street, :city, :state, :zip].each do |field|
          if loc[field] != rec[field]
            @log.warn("make_location: voting_locations(id #{loc[:id]}): inconsistent \"#{field}\" values [\"#{loc[field]}\", \"#{rec[field]}\"]")
          end
        end
        return loc
      end

      id = @db[:voting_locations].insert(rec)
      @db[:voting_locations][:id => id]
    end


    def make_schedule(hours)
      id = @db[:voting_schedules].insert({:formatted => format_schedule(hours).join("\n")})
      hours.each do |h|
        add_schedule_entry(id, h) unless is_closed_today(h)
      end
      @db[:voting_schedules][:id => id]
    end

    def append_schedule(id, hours)
      add_schedule_entry(id, hours)
      sched = @db[:voting_schedules].filter(:id => id)
      sched.update(:formatted => sched.get(:formatted) + "\n" + format_schedule_line(hours))
    end

    def add_schedule_entry(id, h)
      raise "bad schedule range: #{h}" if h.first >= h.last || h.first.yday != h.last.yday || h.first.year != h.last.year
      @db[:voting_schedule_entries] << {
        :schedule_id => id,
        :opens => h.first,
        :closes => h.last,
      }
      id
    end


    def load_eday_places(infile, hours)
      @log.info("load_eday_places: loading \"#{infile}\" ...")

      # Create schedule record for election day.
      schedule = make_schedule([hours])

      CSV.foreach(infile, :headers => true) do |row|

        cleanup_row(row)

        ensure_not_empty(row, @col_name[:PCT])
        precinct = row[@col_name[:PCT]].to_i
        raise "failed to parse precinct from: #{row}" if precinct == 0

        location = make_location(row)

        notes = nil
        unless row[@col_name[:COMBINED_PCTS]].empty?
          a = [precinct] + row[@col_name[:COMBINED_PCTS]].split(",").map {|s| s.to_i}
          notes = "Combined precincts " + a.sort.join(", ")
        end

        @db[:voting_places] << {
          :place_type => "ELECTION_DAY",
          :title => "Precinct #{precinct}",
          :precinct => precinct,
          :location_id => location[:id],
          :schedule_id => schedule[:id],
          :notes => notes,
        }

      end
    end


    def load_evfixed_places(infile, hours_by_code)
      @log.info("load_evfixed_places: loading \"#{infile}\" ...")

      # Create schedule records and formatted displays for early voting schedules.
      schedule_by_code = {}
      hours_by_code.each do |code, hours|
        schedule_by_code[code] = make_schedule(hours)
      end

      CSV.foreach(infile, :headers => true) do |row|

        cleanup_row(row)

        location = make_location(row)

        schedule_code = row[@col_name[:SCHEDULE_CODE]]
        schedule = schedule_by_code[schedule_code]
        raise "unknown schedule code \"#{schedule_code}\": #{row}" unless schedule

        @db[:voting_places] << {
          :place_type => "EARLY_FIXED",
          :title => "Early Voting Location",
          :location_id => location[:id],
          :schedule_id => schedule[:id],
          :notes => nil,
        }

      end
    end


    def load_evmobile_places(infile)
      @log.info("load_evmobile_places: loading \"#{infile}\" ...")

      CSV.foreach(infile, :headers => true) do |row|

        cleanup_row(row)

        location = make_location(row)

        hours = get_datetimes(row)

        place = @db[:voting_places] \
          .filter(:place_type => "EARLY_MOBILE") \
          .filter(:location_id => location[:id]) \
          .limit(1)

        if place.empty?
          schedule = make_schedule([hours])

          @db[:voting_places] << {
            :place_type => "EARLY_MOBILE",
            :title => "Mobile Early Voting Location",
            :location_id => location[:id],
            :schedule_id => schedule[:id],
            :notes => nil,
          }
        else
          append_schedule(place.get(:schedule_id), hours)
        end

      end

    end


  end
end


# Add #cleanup methods used by VoteATX::Loader#cleanup_row.

class String
  def cleanup
    strip
  end
end

class Array
  def cleanup
    map {|e| e.cleanup}
  end
end

class NilClass
  def cleanup
    nil
  end
end
