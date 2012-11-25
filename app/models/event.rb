# -*- coding: utf-8 -*-
class Event < ActiveRecord::Base
  class ExtraTagContainer < Hash
    class TagContainer < Array
      def names_str
        names.join(' ')
      end
      
      def names_str=(v)
        self.names = v.strip.split(%r{(?:\s|/)+})
      end
      
      def names
        map {|t| t.try(:name) }.compact
      end
      
      def names=(v)
        self.clear
        v.compact.each {|t| push Tag.find_or_create_by_name(t) }
      end
    end

    def initialize(event)
      super()
      @loaded = false
      @event = event
    end
    attr_accessor :event

    def loaded?
      @loaded
    end

    def load
      loaded? and return self
      @loaded = true
      clear
      @event.extra_tag_relations.each do |r|
        fetch(r.target_field) {
          store(r.target_field, TagContainer.new)
        } << r.tag
      end
      self
    end

    def save
      new_rels = []
      each do |field, tags|
        i = 1
        tags.each do |tag|
          new_rels << EventTagRelation.find_or_create_by_tag_id_and_event_id_and_target_field_and_pos(tag.id, @event.id, field, i)
          i += 1
        end
      end
      @event.extra_tag_relation_ids = new_rels.map {|r| r.id}
    end
    alias_method :save!, :save

    def []=(k, v)
      load
      super(k.to_s, v)
    end

    def [](k)
      load
      fetch(k.to_s) {
        store(k.to_s, TagContainer.new)
      }
    end
  end

  scope :active, where(:status => 'confirmed')
  scope :by_tag_ids, (lambda do |ids|
    joins(:all_tag_relations).where('event_tag_relations.tag_id' => ids)
  end)
  scope :search, (lambda do |query|
    sqls = []
    args = []
    tag_ids = []
    query.strip.split(/[　 \t\n\r]+/).each do |q|
      q.blank? and next
      qw = "%#{query}%"
      args += [qw, qw]
      sqls << "lower(summary) like lower(?) or lower(description) like lower(?)"
      tag_ids << Tag.find_by_name(q).try(:id)
    end
    tag_ids.compact!
    unless tag_ids.empty?
      sqls <<  "event_tag_relations.tag_id IN (?)"
      args << tag_ids
    end
    sqls.empty? and return
    joins(:all_tag_relations).where(sqls.join(' or '), *args)
  end)

  tagrel_opts = {
    :class_name => 'EventTagRelation',
    :order => 'target_field, pos',
  }
  has_many :all_tag_relations,   tagrel_opts.merge(:dependent => :delete_all)
  has_many :main_tag_relations,  tagrel_opts.merge(:conditions => {:target_field => ""})
  has_many :extra_tag_relations, tagrel_opts.merge(:conditions => "target_field != ''")

  has_many :all_tags,  :through => :all_tag_relations
  has_many :tags,      :through => :main_tag_relations
  
  has_one :reccuring_parent, :class_name => 'Event',
    :foreign_key => 'g_recurring_event_id', :primary_key => 'g_id'
  has_many :histories, :class_name => 'History',
    :conditions => {:target => 'event'}, :foreign_key => 'target_id'

  has_many :uris, :autosave => true, :dependent => :destroy

  mount_uploader :image, EventImageUploader

  accepts_nested_attributes_for :uris, :tags
  attr_accessible :g_calendar_id, :description, :etag, :g_html_link,
    :location, :status, :summary, :g_color_id, :g_creator_email,
    :g_creator_display_name, :start_date, :start_datetime,
    :end_date, :end_datetime, :g_id, :recur_string,
    :ical_uid, :country, :lang, :allday, :twitter_hash,
    :uris_attributes, :tags_attributes, :timezone

  validates :g_id, :uniqueness => true, :allow_nil => true
  validates :etag, :presence => true
  validates :summary, :presence => true, :if => :active?
  validates :start_datetime, :presence => true, :if => :active?
  validates :end_datetime, :presence => true, :if => :active?
  validates :start_date, :presence => true, :if => :active?
  validates :end_date, :presence => true, :if => :active?
  validates :ical_uid, :presence => true, :if => :active?
  validates :tz_min, :numericality => {:only_integer => true}, :allow_nil => true
  validates :status, :presence => true, :inclusion => {:in => %w(confirmed cancelled)}
  validates :recur_orig_start_datetime,
    :presence => true, :if => :recurring_instance?
  validates :recur_orig_start_date,
    :presence => true, :if => :recurring_instance?

  before_validation :set_dummy_values_for_cancelled,
    :cascade_start_date, :cascade_end_datetime, :cascade_end_date,
    :mangle_tentative_status

  after_save :save_tag_order, :save_extra_tags

  after_initialize :init
  def init
    @extra_tags = ExtraTagContainer.new(self)
    @tag_changed = false
  end
  attr_reader :extra_tags

  def name
    summary
  end

  def recurring_instance?
    !self[:g_recurring_event_id].blank?
  end

  def cancelled?
    status == "cancelled"
  end
  alias_method :deleted?, :cancelled?

  def active?
    !cancelled?
  end

  def timezone
    self[:timezone].blank? and return nil
    @_timezone ||= ActiveSupport::TimeZone.new(self[:timezone])
  end

  def timezone=(v)
    self[:timezone] = v
    v.blank? and return
    @_timezone = ActiveSupport::TimeZone.new(v)
    self[:tz_min] = @_timezone.utc_offset / 60
  end

  def tz_min=(v)
    raise ArgumentError, "Use Event#timezone= instead."
  end

  def timezone_offset
    Rational.new(timezone.utc_offset/60, 24*60)
  end

  def start_datetime=(v)
    v = convert_to_datetime v
    self[:start_datetime] = v
    self[:start_date] = v.to_date
  end

  def end_datetime=(v)
    v = convert_to_datetime v
    self[:end_datetime] = v
    self[:end_date] = v.to_date
  end

  def start_date=(v)
    v = convert_to_date v
    self[:start_date] = v
    self[:start_datetime] = Time.new(v.year, v.mon, v.day).to_datetime
  end

  def end_date=(v)
    v = convert_to_date v
    self[:end_date] = v
    self[:end_datetime] = Time.new(v.year, v.mon, v.day).to_datetime
  end

  def recur_orig_start_datetime=(v)
    v = convert_to_datetime v
    self[:recur_orig_start_datetime] = v
    self[:recur_orig_start_date] = v.to_date
  end

  def recur_orig_start_date=(v)
    v = convert_to_date v
    self[:recur_orig_start_date] = v
    self[:recur_orig_start_datetime] = Time.new(v.year, v.mon, v.day).to_datetime
  end

  def start_at
    allday? ? start_date : start_datetime
  end

  def end_at
    allday? or return end_datetime
    d = end_date
    DateTime.new(d.year, d.mon, d.day, 0, 0, 0, end_datetime.to_datetime.offset) < end_datetime and
      return (end_datetime + 1.day).to_date
    end_date
  end

  def time_until
    allday? or return end_datetime - 1.second
    end_at - 1.day
  end

  def time_range
    start_at...end_at
  end

  def term_str
    # TODO: Internationalization support!
    s = start_at
    e = allday? ? time_until : end_datetime # Use end_datetime as user friendly display when event is not allday.
    year_fmt = ""
    s.year != e.year || s.year != Date.today.year and
      year_fmt = "%Y-"
    ret = s.strftime("#{year_fmt}%m-%d")
    allday? or ret << s.strftime(" %H:%M")
    appends = ""
    if s.year != e.year || s.month != e.month || s.day != e.day
      appends << e.strftime("#{year_fmt}%m-%d")
    end
    if !allday? && (!appends.blank? || s.hour != e.hour || s.min != e.min)
      !appends.blank? and appends << " "
      appends << e.strftime("%H:%M")
    end
    appends.blank? or ret += " - #{appends}"
    ret
  end

  def tag_names_str
    self.tag_names.join(' ')
  end

  def tag_names_str=(v)
    self.tag_names = v.strip.split(%r{(?:\s|/)+})
  end

  def tag_names
    self.tags.map {|t| t.try(:name) }.compact
  end

  def tag_names=(v)
    @tag_changed = true
    updated_at_will_change!
    self.tags = v.compact.map {|t| Tag.find_or_create_by_name(t) }
  end

  def has_end_time?
    allday? && start_date != (end_date - 1.day) ||
      !allday? && start_datetime != end_datetime
  end

  def g_html_link=(v)
    self[:g_html_link] = v
    if !v.blank? && v =~ /eid=([^;&]+)/
      self[:g_eid] = $1
    else
      self[:g_eid] = nil
    end
  end

  def g_eid=(v)
    self[:g_eid] = v
    if v.blank?
      self[:g_html_link] = nil
    else
      self[:g_html_link] = "https://www.google.com/calendar/event?eid=#{v}"
    end
  end

  # Load attribute has from externel exchange format (e.g. google API)
  def load_exfmt(format, attrs, opts = {})
    self.respond_to? "load_exfmt_#{format}" or
      raise ArgumentError, "Exchange format #{format} is not supported"
    self.__send__ "load_exfmt_#{format}", attrs, opts
  end

  def load_exfmt_google_v3(attrs, opts = {})
    opts = {:tag_names_remove => [], :tag_names_append => []}.merge opts
    default_timezone = opts[:default_timezone] || Time.zone.name
    opts[:calendar_id].blank? and
      raise ArgumentError, "Need to specify :calendar_id as option"

    summary = attrs["summary"].to_s.strip
    tag_names = opts[:tag_names_append]
    while summary.sub!(/^【(.*?)】/, '')
      tag_names += $1.split(%r{[/／]+}).map {|t| t.strip }.compact
    end
    summary.sub!(/^★/, '') and tag_names << '記念日'
    self.tag_names = (tag_names - opts[:tag_names_remove]).uniq

    self.assign_attributes({
      g_id: attrs.id,
      etag: attrs.etag,
      status: attrs.status,
      summary: summary.strip,
      description: attrs["description"],
      location: attrs["location"],
      g_html_link: attrs["htmlLink"],
      g_calendar_id: opts[:calendar_id],
      g_creator_email: attrs["creator"].try(:email),
      g_creator_display_name: attrs["creator"].try(:display_name),
      ical_uid: attrs["iCalUID"].to_s,
    }, :without_protection => true)
    if attrs["start"]
      self.assign_attributes({
        start_date: attrs.start["date"] || attrs.start.dateTime.to_date,
        start_datetime: attrs.start["dateTime"] || attrs.start.date.to_time.to_datetime,
        end_date: attrs.end["date"] || attrs.end.dateTime.to_date,
        end_datetime: attrs.end["dateTime"] || attrs.end.date.to_time.to_datetime,
        timezone: attrs.start["timeZone"] || default_timezone,
        allday: !!attrs.start["date"],
        recur_string: attrs.recurrence.to_a.join("\n"),
      }, :without_protection => true)
    end
    if attrs.recurringEventId
      orig_sd = attrs["originalStartTime"]
      assign_attributes({
        g_recurring_event_id: attrs.recurringEventId,
        recur_orig_start_date: orig_sd["date"] || orig_sd.dateTime.to_date,
        recur_orig_start_datetime: orig_sd["dateTime"] || orig_sd.date.to_time.to_date,
      }, :without_protection => true)
    end
  end

  def to_exfmt(format, opts = {})
    self.respond_to? "to_exfmt_#{format}" or
      raise ArgumentError, "Exchange format #{format} is not supported"
    self.__send__ "to_exfmt_#{format}", opts
  end

  def to_exfmt_google_v3(opts = {})
    opts = {:tag_names_remove => [], :tag_names_append => []}.merge opts
    tag_names = self.tag_names
    has_anniversary = tag_names.delete '記念日'
    tag_str = (opts[:tag_names_append] + tag_names - opts[:tag_names_remove]).uniq.join('/')
    tag_str.blank?  or  tag_str = "【#{tag_str}】"
    has_anniversary and tag_str = "★#{tag_str}"
    summary = tag_str.to_s + self.summary.to_s
    ret = {
      :id => g_id,
      :iCalUID => self.ical_uid,
      :start => 
      if self.allday? 
        {:date => self.start_date}
      else
        {:dateTime => self.start_datetime,
         :timeZone => self.timezone.try(:name)}
      end,
      :end => 
      if self.allday?
        {:date => self.end_date}
      else
        {:dateTime => self.end_datetime,
         :timeZone => self.timezone.try(:name)}
      end,
      :summary => summary,
      :description => self.description,
      :location => self.location,
      :status => self.status,
    }
    recur_string.blank? or
      ret[:recurrence] = self.recur_string.to_s.split("\n")
    if recurring_instance?
      r = {
        :recurringEventId => g_recurring_event_id,
        :originalStartTime =>
        if allday?
          {:date => recur_orig_start_date }
        else
          {:dateTime => recur_orig_start_datetime,
           :timeZone => self.timezone.try(:name) }
        end
      }
      ret.update(r)
    end
    Hashie::Mash.new(ret)
  end

  private
  def cascade_start_date
    self[:start_date] ||= start_datetime.try(:to_date)
    self[:recur_orig_start_date] ||= recur_orig_start_datetime.try(:to_date)
  end

  def cascade_end_datetime
    self[:end_datetime] ||= start_datetime
  end

  def cascade_end_date
    self[:end_date] ||= end_datetime.try(:to_date)
  end

  def mangle_tentative_status
    self.status == "tentative" or return true
    self[:status] = "confirmed"
  end

  def set_dummy_values_for_cancelled
    self.status == "cancelled" or return true
    self[:start_datetime] ||= DateTime.new(1970, 1, 1, 0, 0, 0, 0)
  end

  def save_tag_order
    !tags.loaded? && !@tags_changed and return true
    self.tags.each_with_index do |t, i|
      self.main_tag_relations.each do |r|
        r.tag_id == t.id or next
        r.update_attribute :pos, i+1
      end
    end
    @tag_changed = false
    true
  end

  def save_extra_tags
    extra_tags.save
    true
  end

  def convert_to_date(v)
    v.kind_of?(Date) || v.kind_of?(Time) and return v.to_date
    Date.parse(v.to_s)
  end

  def convert_to_datetime(v)
    v.kind_of?(DateTime) and return v
    v.kind_of?(Time)     and return v.to_datetime
    v.kind_of?(Date)     and return Time.new(v.year, v.mon, v.day)
    DateTime.parse("#{v.to_s} #{Time.zone}")
  end
end
