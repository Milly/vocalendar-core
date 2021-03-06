class User < ActiveRecord::Base
  extend Enumerize
  include VocalendarCore::ModelLogUtils

  scope :admins, ->{ where(:role => 'admin') }
  scope :editors, ->{ where(:role => %w(admin editor))}

  has_many :histories, ->{ where( :target => 'user') }, 
    :class_name => 'History',
    :foreign_key => 'target_id'

  #has_many :favorites

  devise :trackable, :omniauthable
  # for enumerated_attribute
  #enum_attr :role, %w(admin editor)
  enumerize :role, in: [:admin, :editor] #, default: :editor
      
  # rails 4 chenge strong_parameters
  # attr_accessible :name, :email
  # attr_accessible :name, :email, :as => :editor
  # attr_accessible :name, :email, :role, :as => :admin

  validates :twitter_uid, :uniqueness => true, :allow_nil => true
  validates :google_uid,  :uniqueness => true, :allow_nil => true
  validates :google_account, :uniqueness => true, :allow_nil => true
  validates :email, :uniqueness => true, :allow_nil => true

  class << self
    def find_for_google_oauth2(auth, current_user = nil, request = nil)
      !auth || !auth.uid and return nil
      
      # rails 4 find_or_initialize_by_* is deprecated 
      u = current_user || find_or_initialize_by( google_uid: auth.uid )
      c = auth["credentials"]
      u.assign_attributes({
        :google_uid              => auth.uid, # for current_user
        :google_account          => auth["info"]["email"],
        :google_auth_token       => c.token,
        :google_refresh_token    => c.refresh_token,
        :google_token_expires_at => Time.at(c.expires_at).to_datetime,
        :google_token_issued_at  => DateTime.now,
        :google_auth_scope       => auth["scope"],
        :google_auth_valid       => true,
      }
      # TODO んー、外していいのか？
      # , :without_protection => true
      )
      u.email.blank? and u.email = auth["info"]["email"]
      u.name.blank?  and u.name  = auth["info"]["name"] || u.email
      u.auto_created = u.new_record?
      u.new_record? && count(:id) < 1 and u.role = :admin
      u.save!
      u.auto_created? and
        u.adhoc_update_editor_role_by_calendar_membership_info
      u
    end

    def find_for_twitter(auth, current_user = nil)
      !auth || !auth.uid and return nil
      u = current_user || find_or_initialize_by_twitter_uid(auth.uid)
      u.assign_attributes({
        :twitter_uid    => auth.uid, # make sure for current_user
        :twitter_name   => auth["info"]["name"],
        :twitter_nick   => auth["info"]["nickname"],
        :twitter_token  => auth["credentials"]["token"],
        :twitter_secret => auth["credentials"]["secret"],
        :twitter_token_issued_at => DateTime.now,
        :twitter_auth_valid => true,
      })#, :without_protection => true)
      u.auto_created = u.new_record?
      u.name.blank? and u.name = auth["info"]["name"]
      u.new_record? && count(:id) < 1 and u.role = :admin
      u.save!
      u
    end
  end

  def initalize
    super
    @auto_created = false
  end
  attr_accessor :auto_created

  def auto_created?; !!@auto_created; end

  def provider
    !self[:google_account].blank? ? :google_oauth2 : !self[:twitter_uid].blank? ? :twitter : nil
  end

  def admin?
    self[:role].to_s == 'admin'
  end

  def editor?
    admin? || self[:role].to_s == 'editor'
  end

  # TODO: FIX this function more flexisible...
  def adhoc_update_editor_role_by_calendar_membership_info
    admin? and return
    log :debug, "Cheking calendar ACLs to update role."
    Calendar.where(:io_type => 'src').each do |cal|
      log :debug, "Cheking calendar ACL #{cal.name} to update role."
      begin
        apiret = cal.gapi_request("acl.list")
        apiret.data.items.each do |acl|
          log :debug, "Checking ACL item: #{acl.inspect}"
          acl.role != "owner" && acl.role != "writer" and next
          acl.scope.type  != "user" and next
          acl.scope.value != google_account and next
          log :info, "Write access priv to source calendar found! Setting editor role to the user."
          update_attribute :role, :editor
          return
        end
      rescue => e
        log :error, "Failed to check calendar ACL: #{e.class.name}:#{e.message} to update user role"
      end
    end
    update_attribute :role, nil
  end

  def update_gapi_client_token
    @gapi_client or return false
    auth = @gapi_client.authorization
    auth.expired? or return
    log :debug, "Google API: access token has been expired, trying refresh..."
    begin
      auth.fetch_access_token!
    rescue Signet::AuthorizationError => e
      # This case means to be revoked on google.
      update_attribute :google_auth_valid, false
      raise e
    end
    self.update_attributes!({
      :google_auth_token       => auth.access_token,
      :google_refresh_token    => auth.refresh_token,
      :google_token_expires_at => auth.expires_at,
      :google_token_issued_at  => auth.issued_at,
      :google_auth_valid       => true,
    })
    #, :without_protection => true)
    log :debug, "Google API: access token refresh success."
  end

  def gapi_client
    google_auth_valid? or raise VocalendarCore::GoogleAPIError.new("User ##{id} has no valid google OAuth credentials.")
    if @gapi_client
      update_gapi_client_token
      return @gapi_client
    end
    gac = Google::APIClient.new
    auth = gac.authorization
    auth.client_id     = Rails.configuration.google_client_id
    auth.client_secret = Rails.configuration.google_client_secret

    auth.update_token!({
      :access_token  => google_auth_token,
      :refresh_token => google_refresh_token,
      :expires_in    => google_token_expires_at.to_i - google_token_issued_at.to_i - 30, # -30 sec for early refresh...
      :issued_at     => google_token_issued_at,
    })
    @gapi_client = gac
    update_gapi_client_token
    gac
  end

  def gapi_request(method, params = {}, body = nil, opts = {})
    client = gapi_client
    opts = {:service  => ['calendar', 'v3']}.merge(opts)
    service = client.discovered_api *opts[:service]
    api_method = service
    method.to_s.split('.').each {|m| api_method = api_method.__send__(m) }
    greq = {
      :headers    => {'Content-Type' => 'application/json'},
      :api_method => api_method,
      :parameters => {}.merge(params),
    }
    body and greq[:body] = body
    greq_orig = greq.dup
    log :debug, "Execute Google API request #{api_method.id}"
    result = client.execute(greq)
    if result.status == 401 && !opts[:token_force_reload_tried]
      # Tring to reload token forcely to make sure.
      # In this case, error is caused by revoking auth OR missing scopes.
      # So google_auth_valid may be disabled in this operation.
      update_attribute :google_token_expires_at, Time.at(0)
      update_attribute :google_token_issued_at,  Time.at(0)
      update_gapi_client_token
      return gapi_request method, params, body, opts.merge(:token_force_reload_tried => true)
    elsif result.status < 200 || result.status >= 300
      log :error, "Error on Google API request '#{method}': status=#{result.status}, request=#{greq_orig.inspect} response=#{result.body}"
      raise VocalendarCore::GoogleAPIRequestError.new(result)
    end
    log :debug, "Google API request #{greq[:api_method].id} success (status=#{result.status})"
    result
  end
end
