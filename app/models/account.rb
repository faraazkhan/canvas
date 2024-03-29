#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Account < ActiveRecord::Base
  include Context
  attr_accessible :name, :turnitin_account_id,
    :turnitin_shared_secret, :turnitin_comments, :turnitin_pledge,
    :default_time_zone, :parent_account, :settings, :default_storage_quota,
    :default_storage_quota_mb, :storage_quota, :ip_filters, :default_locale

  include Workflow
  belongs_to :parent_account, :class_name => 'Account'
  belongs_to :root_account, :class_name => 'Account'
  authenticates_many :pseudonym_sessions
  has_many :courses
  has_many :all_courses, :class_name => 'Course', :foreign_key => 'root_account_id'
  has_many :group_categories, :as => :context, :conditions => ['deleted_at IS NULL']
  has_many :all_group_categories, :class_name => 'GroupCategory', :as => :context
  has_many :groups, :as => :context
  has_many :enrollment_terms, :foreign_key => 'root_account_id'
  has_many :enrollments, :foreign_key => 'root_account_id'
  has_many :sub_accounts, :class_name => 'Account', :foreign_key => 'parent_account_id', :conditions => ['workflow_state != ?', 'deleted']
  has_many :all_accounts, :class_name => 'Account', :foreign_key => 'root_account_id', :order => 'name'
  has_many :account_users, :dependent => :destroy
  has_many :course_sections, :foreign_key => 'root_account_id'
  has_many :learning_outcomes, :as => :context
  has_many :sis_batches
  has_many :abstract_courses, :class_name => 'AbstractCourse', :foreign_key => 'account_id'
  has_many :root_abstract_courses, :class_name => 'AbstractCourse', :foreign_key => 'root_account_id'
  has_many :users, :through => :account_users
  has_many :pseudonyms, :include => :user
  has_many :role_overrides, :as => :context
  has_many :rubrics, :as => :context
  has_many :rubric_associations, :as => :context, :include => :rubric, :dependent => :destroy
  has_many :course_account_associations
  has_many :associated_courses, :through => :course_account_associations, :source => :course, :select => 'DISTINCT courses.*'
  has_many :child_courses, :through => :course_account_associations, :source => :course, :conditions => ['course_account_associations.depth = 0']
  has_many :attachments, :as => :context, :dependent => :destroy
  has_many :active_assignments, :as => :context, :class_name => 'Assignment', :conditions => ['assignments.workflow_state != ?', 'deleted']
  has_many :folders, :as => :context, :dependent => :destroy, :order => 'folders.name'
  has_many :active_folders, :class_name => 'Folder', :as => :context, :conditions => ['folders.workflow_state != ?', 'deleted'], :order => 'folders.name'
  has_many :active_folders_with_sub_folders, :class_name => 'Folder', :as => :context, :include => [:active_sub_folders], :conditions => ['folders.workflow_state != ?', 'deleted'], :order => 'folders.name'
  has_many :active_folders_detailed, :class_name => 'Folder', :as => :context, :include => [:active_sub_folders, :active_file_attachments], :conditions => ['folders.workflow_state != ?', 'deleted'], :order => 'folders.name'
  has_many :account_authorization_configs, :order => 'id'
  has_many :account_reports
  has_many :grading_standards, :as => :context
  has_many :assessment_questions, :through => :assessment_question_banks
  has_many :assessment_question_banks, :as => :context, :include => [:assessment_questions, :assessment_question_bank_users]
  def inherited_assessment_question_banks(include_self = false, *additional_contexts)
    sql = []
    conds = []
    contexts = additional_contexts + account_chain
    contexts.delete(self) unless include_self
    contexts.each { |c|
      sql << "context_type = ? AND context_id = ?"
      conds += [c.class.to_s, c.id]
    }
    conds.unshift(sql.join(" OR "))
    AssessmentQuestionBank.scoped :conditions => conds
  end
  
  has_many :context_external_tools, :as => :context, :dependent => :destroy, :order => 'name'
  has_many :learning_outcomes, :as => :context
  has_many :learning_outcome_groups, :as => :context
  has_many :created_learning_outcomes, :class_name => 'LearningOutcome', :as => :context
  has_many :learning_outcome_tags, :class_name => 'ContentTag', :as => :context, :conditions => ['content_tags.tag_type = ? AND workflow_state != ?', 'learning_outcome_association', 'deleted']
  has_many :associated_learning_outcomes, :through => :learning_outcome_tags, :source => :learning_outcome
  has_many :page_views
  has_many :error_reports
  has_many :account_notifications
  has_many :alerts, :as => :context, :include => :criteria
  has_many :associated_alerts, :through => :associated_courses, :source => :alerts, :include => :criteria
  has_many :user_account_associations

  before_validation :verify_unique_sis_source_id
  before_save :ensure_defaults
  before_save :set_update_account_associations_if_changed
  after_save :update_account_associations_if_changed
  after_create :default_enrollment_term
  
  serialize :settings, Hash

  scopes_custom_fields

  validates_locale :default_locale, :allow_nil => true

  include StickySisFields
  are_sis_sticky :name

  def default_locale(recurse = false)
    read_attribute(:default_locale) ||
    (recurse && parent_account ? parent_account.default_locale(true) : nil)
  end

  cattr_accessor :account_settings_options
  self.account_settings_options = {}
  
  # I figure we're probably going to be adding more account-level
  # settings in the future (and moving some of the column attributes
  # to the settings hash), so it makes sense to have a general way
  # of defining what settings are allowed when.  Somebody please tell
  # me if I'm overarchitecting...
  def self.add_setting(setting, opts=nil)
    self.account_settings_options[setting.to_sym] = opts || {}
    if (opts && opts[:boolean] && opts.has_key?(:default))
      if opts[:default]
        self.class_eval "def #{setting}?; settings[:#{setting}] != false; end"
      else
        self.class_eval "def #{setting}?; !!settings[:#{setting}]; end"
      end
    end
  end
  
  # these settings either are or could be easily added to
  # the account settings page
  add_setting :global_javascript, :condition => :global_includes, :root_only => true
  add_setting :global_stylesheet, :condition => :global_includes, :root_only => true
  add_setting :error_reporting, :hash => true, :values => [:action, :email, :url, :subject_param, :body_param], :root_only => true
  add_setting :prevent_course_renaming_by_teachers, :boolean => true, :root_only => true
  add_setting :teachers_can_create_courses, :boolean => true, :root_only => true, :default => false
  add_setting :students_can_create_courses, :boolean => true, :root_only => true, :default => false
  add_setting :no_enrollments_can_create_courses, :boolean => true, :root_only => true, :default => false
  add_setting :allow_sending_scores_in_emails, :boolean => true, :root_only => true
  add_setting :support_url, :root_only => true
  add_setting :self_enrollment
  add_setting :equella_endpoint
  add_setting :equella_teaser
  add_setting :enable_alerts, :boolean => true, :root_only => true
  add_setting :enable_eportfolios, :boolean => true, :root_only => true
  add_setting :users_can_edit_name, :boolean => true, :root_only => true
  add_setting :open_registration, :boolean => true, :root_only => true, :default => false
  
  def settings=(hash)
    if hash.is_a?(Hash)
      hash.each do |key, val|
        if account_settings_options && account_settings_options[key.to_sym]
          opts = account_settings_options[key.to_sym]
          if (opts[:root_only] && root_account_id) || (opts[:condition] && !settings[opts[:condition].to_sym])
            settings.delete key.to_sym
          elsif opts[:boolean]
            settings[key.to_sym] = (val == true || val == 'true' || val == '1' || val == 'on')
          elsif opts[:hash]
            new_hash = {}
            if val.is_a?(Hash)
              val.each do |inner_key, inner_val|
                if opts[:values].include?(inner_key.to_sym)
                  new_hash[inner_key.to_sym] = inner_val.to_s
                end
              end
            end
            settings[key.to_sym] = new_hash.empty? ? nil : new_hash
          else
            settings[key.to_sym] = val.to_s
          end
        end
      end
    end
    settings
  end
  
  def ip_filters=(params)
    filters = {}
    require 'ipaddr'
    params.each do |key, str|
      ips = []
      vals = str.split(/,/)
      vals.each do |val|
        ip = IPAddr.new(val) rescue nil
        # right now the ip_filter column on quizzes is just a string,
        # so it has a max length.  I figure whatever we set it to this
        # setter should at the very least limit stored values to that
        # length.
        ips << val if ip && val.length <= 255 
      end
      filters[key] = ips.join(',') unless ips.empty?
    end
    settings[:ip_filters] = filters
  end
  
  def ensure_defaults
    self.uuid ||= AutoHandle.generate_securish_uuid
  end
  
  def verify_unique_sis_source_id
    return true unless self.sis_source_id
    root = self.root_account || self
    existing_account = Account.find_by_root_account_id_and_sis_source_id(root.id, self.sis_source_id)
    
    if self.root_account?
      return true if !existing_account
    elsif root.sis_source_id != self.sis_source_id
      return true if !existing_account || existing_account.id == self.id
    end
    
    self.errors.add(:sis_source_id, t('#account.sis_id_in_use', "SIS ID \"%{sis_id}\" is already in use", :sis_id => self.sis_source_id))
    false
  end
  
  def set_update_account_associations_if_changed
    self.root_account_id ||= self.parent_account.root_account_id if self.parent_account
    self.root_account_id ||= self.parent_account_id
    self.parent_account_id ||= self.root_account_id
    Account.invalidate_cache(self.id) if self.id
    @should_update_account_associations = self.parent_account_id_changed? || self.root_account_id_changed?
    true
  end
  
  def update_account_associations_if_changed
    send_later_if_production(:update_account_associations) if @should_update_account_associations
  end
  
  def equella_settings
    endpoint = self.settings[:equella_endpoint] || self.equella_endpoint
    if !endpoint.blank?
      OpenObject.new({
        :endpoint => endpoint,
        :default_action => self.settings[:equella_action] || 'selectOrAdd',
        :teaser => self.settings[:equella_teaser]
      })
    else
      nil
    end
  end
  
  def settings
    result = self.read_attribute(:settings)
    return result if result
    return self.write_attribute(:settings, {}) unless frozen?
    {}.freeze
  end
  
  def domain
    HostUrl.context_host(self)
  end
  
  def root_account?
    !self.root_account_id
  end
  
  def sub_accounts_as_options(indent = 0, preloaded_accounts = nil)
    unless preloaded_accounts
      preloaded_accounts = {}
      (self.root_account || self).all_accounts.active.each do |account|
        (preloaded_accounts[account.parent_account_id] ||= []) << account
      end
    end
    res = [[("&nbsp;&nbsp;" * indent).html_safe + self.name, self.id]]
    if preloaded_accounts[self.id]
      preloaded_accounts[self.id].each do |account|
        res += account.sub_accounts_as_options(indent + 1, preloaded_accounts)
      end
    end
    res
  end
  
  def users_name_like(query="")
    @cached_users_name_like ||= {}
    @cached_users_name_like[query] ||= self.fast_all_users.name_like(query)
  end

  def fast_course_base(opts)
    columns = "courses.id, courses.name, courses.workflow_state, courses.course_code, courses.sis_source_id"
    associated_courses = self.associated_courses.active
    associated_courses = associated_courses.with_enrollments if opts[:hide_enrollmentless_courses]
    associated_courses = associated_courses.for_term(opts[:term]) if opts[:term].present?
    associated_courses = yield associated_courses if block_given?
    associated_courses.limit(opts[:limit]).active_first.find(:all, :select => columns, :group => columns)
  end

  def fast_all_courses(opts={})
    @cached_fast_all_courses ||= {}
    @cached_fast_all_courses[opts] ||= self.fast_course_base(opts)
  end

  def all_users(limit=250)
    @cached_all_users ||= {}
    @cached_all_users[limit] ||= User.of_account(self).scoped(:limit=>limit)
  end
  
  def fast_all_users(limit=nil)
    @cached_fast_all_users ||= {}
    @cached_fast_all_users[limit] ||= self.all_users(limit).active.order_by_sortable_name.scoped(:select => "users.id, users.name, users.sortable_name")
  end

  def users_not_in_groups_sql(groups, opts={})
    ["SELECT u.id, u.name
        FROM users u
       INNER JOIN user_account_associations uaa on uaa.user_id = u.id
       WHERE uaa.account_id = ? AND u.workflow_state != 'deleted'
             #{"AND NOT EXISTS (SELECT *
                                  FROM group_memberships gm
                                 WHERE gm.user_id = u.id AND
                                       gm.group_id IN (#{groups.map(&:id).join ','}))" unless groups.empty?}
       #{"ORDER BY #{opts[:order_by]}" if opts[:order_by].present?}", self.id]
  end

  def users_not_in_groups(groups)
    User.find_by_sql(users_not_in_groups_sql(groups))
  end
  
  def paginate_users_not_in_groups(groups, page, per_page = 15)
    User.paginate_by_sql(users_not_in_groups_sql(groups, :order_by => "#{User.sortable_name_order_by_clause('u')} ASC"),
                         :page => page, :per_page => per_page)
  end

  def courses_name_like(query="", opts={})
    opts[:limit] ||= 200
    @cached_courses_name_like ||= {}
    @cached_courses_name_like[[query, opts]] ||= self.fast_course_base(opts) {|q| q.name_like(query)}
  end

  def file_namespace
    root = self.root_account || self
    "account_#{root.id}"
  end
  
  def self.account_lookup_cache_key(id)
    ['_account_lookup2', id].cache_key
  end
  
  def find_user_by_unique_id(unique_id)
    self.pseudonyms.find_by_unique_id(unique_id_or_email).user rescue nil
  end
  
  def clear_cache_keys!
    Rails.cache.delete(self.id)
    true
  end
  
  def self.invalidate_cache(id)
    Rails.cache.delete(account_lookup_cache_key(id)) if id
  rescue 
    nil
  end
  
  def quota
    Rails.cache.fetch(['current_quota', self].cache_key) do
      read_attribute(:storage_quota) ||
        (self.parent_account.default_storage_quota rescue nil) ||
        Setting.get_cached('account_default_quota', 500.megabytes.to_s).to_i
    end
  end
  
  def default_storage_quota
    read_attribute(:default_storage_quota) || 
      (self.parent_account.default_storage_quota rescue nil) ||
      Setting.get_cached('account_default_quota', 500.megabytes.to_s).to_i
  end
  
  def default_storage_quota_mb
    default_storage_quota / 1.megabyte
  end
  
  def default_storage_quota_mb=(val)
    self.default_storage_quota = val.try(:to_i).try(:megabytes)
  end
  
  def default_storage_quota=(val)
    val = val.to_f
    val = nil if val <= 0
    # If the value is the same as the inherited value, then go
    # ahead and blank it so it keeps using the inherited value
    if parent_account && parent_account.default_storage_quota == val
      val = nil
    end
    write_attribute(:default_storage_quota, val)
  end
  
  def has_outcomes?
    self.learning_outcomes.count > 0
  end
  
  def turnitin_shared_secret=(secret)
    return if secret.blank?
    self.turnitin_crypted_secret, self.turnitin_salt = Canvas::Security.encrypt_password(secret, 'instructure_turnitin_secret_shared')
  end
  
  def turnitin_shared_secret
    return nil unless self.turnitin_salt && self.turnitin_crypted_secret
    Canvas::Security.decrypt_password(self.turnitin_crypted_secret, self.turnitin_salt, 'instructure_turnitin_secret_shared')
  end
  
  def account_chain(opts = {})
    res = [self]
    account = self
    while account.parent_account
      account = account.parent_account
      res << account
    end
    res << self.root_account unless res.include?(self.root_account)
    res << Account.site_admin if opts[:include_site_admin] && !self.site_admin?
    res.compact
  end
  
  def account_chain_ids(opts={})
    account_chain(opts).map(&:id)
  end
  memoize :account_chain_ids
  
  def all_page_views
    PageView.of_account(self)
  end
  
  def membership_for_user(user)
    self.account_users.find_by_user_id(user && user.id)
  end
  
  def page_views_by_day(*args)
    dates = (!args.empty? && args) || [1.year.ago, Time.now ]
    PageView.count(
      :group => "date(created_at)", 
      :order => "date(created_at)",
      :conditions => {
        :account_id => self_and_all_sub_accounts,
        :created_at => (dates.first)..(dates.last)
      }
    )
  end
  memoize :page_views_by_day
  
  def page_views_by_hour(*args)
    dates = (!args.empty? && args) || [1.year.ago, Time.now ]
    group = case PageView.connection.adapter_name
    when "SQLite"
      "strftime('%H', created_at)"
    else
      "extract(hour from created_at)"
    end
    PageView.count(
      :group => group,
      :order => group,
      :conditions => {
        :account_id => self_and_all_sub_accounts,
        :created_at => (dates.first)..(dates.last)
      }
    )
  end
  memoize :page_views_by_hour
  
  def page_view_hourly_report(*args)
    # if they dont supply a date range then use the first day returned by page_views_by_day (which should be the first day that there is pageview statistics gathered)
    hours = []
    max = page_views_by_hour(*args).map{|key, val| val}.compact.max
    24.times do |hour|
      utc_hour = ActiveSupport::TimeWithZone.new(Time.parse("#{hour}:00"), Time.zone).utc.hour
      hours << [hour, ((page_views_by_hour(*args)[utc_hour.to_s].to_f / max.to_f * 100.0).to_i rescue 0) ]
    end
    hours
  end
  
  def page_view_data(*args)
    # if they dont supply a date range then use the first day returned by page_views_by_day (which should be the first day that there is pageview statistics gathered)
    dates = args.empty? ? [page_views_by_day.sort.first.first.to_datetime, Time.now] : args 
    days = []
    dates.first.to_datetime.upto(dates.last) do |d| 
      # this * 1000 part is because the Highcharts expects something like what Date.UTC(2006, 2, 28) would give you,
      # which is MILLISECONDS from the unix epoch, ruby's to_f gives you SECONDS since then.
      days << [ (d.at_beginning_of_day.to_f * 1000).to_i , page_views_by_day[d.to_date.to_s].to_i ]
    end
    days
  rescue
    return []
  end
  memoize :page_view_data
  
  def most_popular_courses(options={})
    conditions = {
      :account_id => self_and_all_sub_accounts
    }
    if options[:dates]
      conditions.merge!({
        :created_at => (options[:dates].first)..(options[:dates].last)
      })
    end
    PageView.scoped(
      :select => 'count(*) AS page_views_count, context_type, context_id',
      :group => "context_type, context_id", 
      :conditions => conditions,
      :order => "page_views_count DESC"
    ).map do |context|
      context.attributes.merge({"page_views_count" => context.page_views_count.to_i}).with_indifferent_access
    end
  end
  memoize :most_popular_courses
  
  def popularity_of(context)
    index = most_popular_courses.index( most_popular_courses.detect { |i| 
      i[:context_type] == context.class.to_s && i[:context_id] == context.id 
    })
    index ? 
      { :rank => index, :page_views_count => most_popular_courses[index][:page_views_count] } :
      { :rank => courses.count, :page_views_count => 0 } 
  end
  memoize :popularity_of
  
  def account_membership_types
    res = ['AccountAdmin']
    res += self.parent_account.account_membership_types if self.parent_account
    res += (self.membership_types || "").split(",").select{|t| !t.empty? }
    res.uniq
  end
  
  def add_account_membership_type(type)
    types = account_membership_types
    types += type.split(",")
    self.membership_types  = types.join(',')
    self.save
  end
  
  def remove_account_membership_type(type)
    self.membership_types = self.account_membership_types.select{|t| t != type}.join(',')
    self.save
  end

  def account_authorization_config
    # We support multiple auth configs per account, but several places we assume there is only one.
    # This is for compatibility with those areas. TODO: migrate everything to supporting multiple
    # auth configs
    self.account_authorization_configs.first
  end
  
  def login_handle_name_is_customized?
    self.account_authorization_config && self.account_authorization_config.login_handle_name.present?
  end
  
  def login_handle_name
    login_handle_name_is_customized? ? self.account_authorization_config.login_handle_name :
        (self.delegated_authentication? ? AccountAuthorizationConfig.default_delegated_login_handle_name :
            AccountAuthorizationConfig.default_login_handle_name)
  end
  
  def self_and_all_sub_accounts
    @self_and_all_sub_accounts ||= Account.connection.select_all("SELECT id FROM accounts WHERE accounts.root_account_id = #{self.id} OR accounts.parent_account_id = #{self.id}").map{|ref| ref['id'].to_i}.uniq + [self.id]
  end
  
  def default_time_zone
    read_attribute(:default_time_zone) || "Mountain Time (US & Canada)"
  end
  
  workflow do
    state :active
    state :deleted
  end

  def account_users_for(user)
    @account_chain_ids ||= self.account_chain(:include_site_admin => true).map { |a| a.active? ? a.id : nil }.compact
    @account_users_cache ||= {}
    @account_users_cache[user] ||= AccountUser.find(:all, :conditions => { :account_id => @account_chain_ids, :user_id => user.id }) if user
    @account_users_cache[user] ||= []
    @account_users_cache[user]
  end
  
  set_policy do
    RoleOverride.permissions.each_key do |permission|
      given { |user| self.account_users_for(user).any? { |au| au.has_permission_to?(permission) } }
      can permission
    end

    given { |user| !self.account_users_for(user).empty? }
    can :read and can :manage and can :update and can :delete

    given { |user|
      root_account = self.root_account || self
      result = false
      site_admin = self.site_admin?

      if !site_admin && user && root_account.teachers_can_create_courses?
        count = user.enrollments.scoped(:select=>'id', :conditions=>"enrollments.type IN ('TeacherEnrollment', 'DesignerEnrollment') AND (enrollments.workflow_state != 'deleted') AND root_account_id = #{root_account.id}").count
        result = true if count > 0
      end
      if !site_admin && user && !result && root_account.students_can_create_courses?
        count = user.enrollments.scoped(:select=>'id', :conditions=>"enrollments.type IN ('StudentEnrollment', 'ObserverEnrollment') AND (enrollments.workflow_state != 'deleted') AND root_account_id = #{root_account.id}").count
        result = true if count > 0
      end
      if !site_admin && user && !result && root_account.no_enrollments_can_create_courses?
        count = user.enrollments.scoped(:select=>'id', :conditions=>"enrollments.workflow_state != 'deleted' AND root_account_id = #{root_account.id}").count
        result = true if count == 0
      end

      result
    }
    can :create_courses
  end

  alias_method :destroy!, :destroy
  def destroy
    self.workflow_state = 'deleted'
    self.deleted_at = Time.now
    save!
  end
  
  def self.site_admin_user?(user, permission = :site_admin)
    !!(user && Account.site_admin.grants_right?(user, permission))
  end
  
  def to_atom
    Atom::Entry.new do |entry|
      entry.title     = self.name
      entry.updated   = self.updated_at
      entry.published = self.created_at
      entry.links    << Atom::Link.new(:rel => 'alternate', 
                                    :href => "/accounts/#{self.id}")
    end
  end
  
  def default_enrollment_term
    return @default_enrollment_term if @default_enrollment_term
    unless self.root_account_id
      @default_enrollment_term = self.enrollment_terms.active.find_or_create_by_name(EnrollmentTerm::DEFAULT_TERM_NAME)
    end
  end
  
  def add_user(user, membership_type = nil)
    return nil unless user && user.is_a?(User)
    membership_type ||= 'AccountAdmin'
    au = self.account_users.find_by_user_id_and_membership_type(user.id, membership_type)
    au ||= self.account_users.create(:user => user, :membership_type => membership_type)
  end
  
  def context_code
    raise "DONT USE THIS, use .short_name instead" unless ENV['RAILS_ENV'] == "production"
  end
  
  def short_name
    name
  end

  def email_pseudonyms
    false
  end
  
  def password_authentication?
    !!(!self.account_authorization_config || self.account_authorization_config.password_authentication?)
  end

  def delegated_authentication?
    !!(self.account_authorization_config && self.account_authorization_config.delegated_authentication?)
  end
  
  def forgot_password_external_url
    account_authorization_config.try(:change_password_url)
  end

  def cas_authentication?
    !!(self.account_authorization_config && self.account_authorization_config.cas_authentication?)
  end
  
  def ldap_authentication?
    !!(self.account_authorization_config && self.account_authorization_config.ldap_authentication?)
  end
  
  def saml_authentication?
    !!(self.account_authorization_config && self.account_authorization_config.saml_authentication?)
  end
  
  def require_account_pseudonym?
    false
  end
  
  # When a user is invited to a course, do we let them see a preview of the
  # course even without registering?  This is part of the free-for-teacher
  # account perks, since anyone can invite anyone to join any course, and it'd
  # be nice to be able to see the course first if you weren't expecting the
  # invitation.
  def allow_invitation_previews?
    self == Account.default
  end
  
  def pseudonym_session_scope
    self.require_account_pseudonym? ? self.pseudonym_sessions : PseudonymSession
  end
  
  def find_courses(string)
    self.all_courses.select{|c| c.name.match(string) }
  end
  
  def find_users(string)
    self.pseudonyms.map{|p| p.user }.select{|u| u.name.match(string) }
  end

  def self.site_admin
    get_special_account('site_admin', 'Site Admin')
  end

  def self.default
    get_special_account('default', 'Default Account')
  end

  def self.get_special_account(special_account_type, default_account_name)
    @special_accounts ||= {}

    if Rails.env.test?
      # TODO: we have to do this because tests run in transactions. maybe it'd
      # be good to create some sort of of memoize_if_safe method, that only
      # memoizes when we're caching classes and not in test mode? I dunno. But
      # this stinks.
      @special_accounts[special_account_type] = Account.find_by_parent_account_id_and_name(nil, default_account_name)
      return @special_accounts[special_account_type] ||= Account.create(:parent_account => nil, :name => default_account_name)
    end

    account = @special_accounts[special_account_type]
    return account if account
    if (account_id = Setting.get("#{special_account_type}_account_id", nil)) && account_id.present?
      account = Account.find_by_id(account_id)
    end
    return @special_accounts[special_account_type] = account if account
    # TODO i18n
    t '#account.default_site_administrator_account_name', 'Site Admin'
    t '#account.default_account_name', 'Default Account'
    account = Account.create!(:name => default_account_name)
    Setting.set("#{special_account_type}_account_id", account.id)
    return @special_accounts[special_account_type] = account
  end

  def site_admin?
    self == Account.site_admin
  end

  def display_name
    self.name
  end

  # Updates account associations for all the courses and users associated with this account
  def update_account_associations
    account_chain_cache = {}
    all_user_ids = []
    all_user_ids += Course.update_account_associations(self.associated_courses, :skip_user_account_associations => true, :account_chain_cache => account_chain_cache)

    # Make sure we have all users with existing account associations.
    # (This should catch users with Pseudonyms associated with the account.)
    all_user_ids += UserAccountAssociation.scoped(:select => 'user_id', :conditions => { :account_id => self.id }).map(&:user_id)

    # Update the users' associations as well
    User.update_account_associations(all_user_ids.uniq, :account_chain_cache => account_chain_cache)
  end
  
  # this will take an account and make it a sub_account of
  # itself.  Also updates all it's descendant accounts to point to
  # the correct root account, and updates the pseudonyms to
  # points to the new root account as well.
  def consume_account(account)
    account.all_accounts.each do |sub_account|
      sub_account.root_account = self.root_account || self
      sub_account.save!
    end
    account.parent_account = self
    account.root_account = self.root_account || self
    account.save!
    account.pseudonyms.each do |pseudonym|
      pseudonym.account = self.root_account || self
      pseudonym.save!
    end
  end
  
  def self.root_account_id_for(obj)
    res = nil
    if obj.respond_to?(:root_account_id)
      res = obj.root_account_id
    elsif obj.respond_to?(:context)
      res = obj.context.root_account_id rescue nil
    end
    raise "Root account ID is undiscoverable for #{obj.inspect}" unless res
  end
  
  def course_count
    self.child_courses.not_deleted.count('DISTINCT course_id')
  end
  memoize :course_count
  
  def sub_account_count
    self.sub_accounts.active.count
  end
  memoize :sub_account_count

  def user_count
    self.user_account_associations.count
  end
  memoize :user_count

  def current_sis_batch
    if (current_sis_batch_id = self.read_attribute(:current_sis_batch_id)) && current_sis_batch_id.present?
      self.sis_batches.find_by_id(current_sis_batch_id)
    end
  end
  
  def turnitin_settings
    if self.turnitin_account_id && self.turnitin_shared_secret && !self.turnitin_account_id.empty? && !self.turnitin_shared_secret.empty?
      [self.turnitin_account_id, self.turnitin_shared_secret]
    else
      self.parent_account.turnitin_settings rescue nil
    end
  end
  
  def closest_turnitin_pledge
    if self.turnitin_pledge && !self.turnitin_pledge.empty?
      self.turnitin_pledge
    else
      res = self.account.turnitin_pledge rescue nil
      res ||= t('#account.turnitin_pledge', "This assignment submission is my own, original work")
    end
  end
  
  def closest_turnitin_comments
    if self.turnitin_comments && !self.turnitin_comments.empty?
      self.turnitin_comments
    else
      self.parent_account.closest_turnitin_comments rescue nil
    end
  end
  
  def self_enrollment_allowed?(course)
    if !settings[:self_enrollment].blank?
      !!(settings[:self_enrollment] == 'any' || (!course.sis_source_id && settings[:self_enrollment] == 'manually_created'))
    else
      !!(parent_account && parent_account.self_enrollment_allowed?(course))
    end
  end
  
  TAB_COURSES = 0
  TAB_STATISTICS = 1
  TAB_PERMISSIONS = 2
  TAB_SUB_ACCOUNTS = 3
  TAB_TERMS = 4
  TAB_AUTHENTICATION = 5
  TAB_USERS = 6
  TAB_OUTCOMES = 7
  TAB_RUBRICS = 8
  TAB_SETTINGS = 9
  TAB_FACULTY_JOURNAL = 10
  TAB_SIS_IMPORT = 11
  TAB_GRADING_STANDARDS = 12
  TAB_QUESTION_BANKS = 13

  def external_tool_tabs(opts)
    tools = ContextExternalTool.find_all_for(self, :account_navigation)
    tools.sort_by(&:id).map do |tool|
     {
        :id => tool.asset_string,
        :label => tool.label_for(:account_navigation, opts[:language]),
        :css_class => tool.asset_string,
        :href => :account_external_tool_path,
        :external => true,
        :args => [self.id, tool.id]
     }
    end
  end
  
  def tabs_available(user=nil, opts={})
    manage_settings = user && self.grants_right?(user, nil, :manage_account_settings)
    if site_admin?
      tabs = []
      tabs << { :id => TAB_PERMISSIONS, :label => t('#account.tab_permissions', "Permissions"), :css_class => 'permissions', :href => :account_permissions_path } if user && self.grants_right?(user, nil, :manage_role_overrides)
    else
      tabs = []
      tabs << { :id => TAB_COURSES, :label => t('#account.tab_courses', "Courses"), :css_class => 'courses', :href => :account_path } if user && self.grants_right?(user, nil, :read_course_list)
      tabs << { :id => TAB_USERS, :label => t('#account.tab_users', "Users"), :css_class => 'users', :href => :account_users_path } if user && self.grants_right?(user, nil, :read_roster)
      tabs << { :id => TAB_STATISTICS, :label => t('#account.tab_statistics', "Statistics"), :css_class => 'statistics', :href => :statistics_account_path } if user && self.grants_right?(user, nil, :view_statistics)
      tabs << { :id => TAB_PERMISSIONS, :label => t('#account.tab_permissions', "Permissions"), :css_class => 'permissions', :href => :account_permissions_path } if user && self.grants_right?(user, nil, :manage_role_overrides)
      if user && self.grants_right?(user, nil, :manage_outcomes)
        tabs << { :id => TAB_OUTCOMES, :label => t('#account.tab_outcomes', "Outcomes"), :css_class => 'outcomes', :href => :account_outcomes_path }
        tabs << { :id => TAB_RUBRICS, :label => t('#account.tab_rubrics', "Rubrics"), :css_class => 'rubrics', :href => :account_rubrics_path }
      end
      tabs << { :id => TAB_GRADING_STANDARDS, :label => t('#account.tab_grading_standards', "Grading Schemes"), :css_class => 'grading_standards', :href => :account_grading_standards_path } if user && self.grants_right?(user, nil, :manage_grades)
      tabs << { :id => TAB_QUESTION_BANKS, :label => t('#account.tab_question_banks', "Question Banks"), :css_class => 'question_banks', :href => :account_question_banks_path } if user && self.grants_right?(user, nil, :manage_grades)
      tabs << { :id => TAB_SUB_ACCOUNTS, :label => t('#account.tab_sub_accounts', "Sub-Accounts"), :css_class => 'sub_accounts', :href => :account_sub_accounts_path } if manage_settings
      tabs << { :id => TAB_FACULTY_JOURNAL, :label => t('#account.tab_faculty_journal', "Faculty Journal"), :css_class => 'faculty_journal', :href => :account_user_notes_path} if self.enable_user_notes && user && self.grants_right?(user, nil, :manage_user_notes)
      tabs << { :id => TAB_TERMS, :label => t('#account.tab_terms', "Terms"), :css_class => 'terms', :href => :account_terms_path } if !self.root_account_id && manage_settings
      tabs << { :id => TAB_AUTHENTICATION, :label => t('#account.tab_authentication', "Authentication"), :css_class => 'authentication', :href => :account_account_authorization_configs_path } if self.parent_account_id.nil? && manage_settings
      tabs << { :id => TAB_SIS_IMPORT, :label => t('#account.tab_sis_import', "SIS Import"), :css_class => 'sis_import', :href => :account_sis_import_path } if self.root_account? && self.allow_sis_import && user && self.grants_right?(user, nil, :manage_sis)
    end
    tabs += external_tool_tabs(opts)
    tabs << { :id => TAB_SETTINGS, :label => t('#account.tab_settings', "Settings"), :css_class => 'settings', :href => :account_settings_path }
    tabs
  end

  def is_a_context?
    true
  end
  
  def custom_feedback_links
    []
  end
  
  def self.allowable_services
    {
      :google_docs => {
        :name => "Google Docs", 
        :description => "",
        :expose_to_ui => !!GoogleDocs.config
      },
      :google_docs_previews => {
        :name => "Google Docs Previews", 
        :description => "",
        :expose_to_ui => true
      },
      :facebook => {
        :name => "Facebook", 
        :description => "",
        :expose_to_ui => !!Facebook.config
      },
      :skype => {
        :name => "Skype", 
        :description => "",
        :expose_to_ui => true
      },
      :linked_in => {
        :name => "LinkedIn", 
        :description => "",
        :expose_to_ui => !!LinkedIn.config
      },
      :twitter => {
        :name => "Twitter", 
        :description => "",
        :expose_to_ui => !!Twitter.config
      },
      :delicious => {
        :name => "Delicious", 
        :description => "",
        :expose_to_ui => true
      },
      :diigo => {
        :name => "Diigo", 
        :description => "",
        :expose_to_ui => true
      },
      # TODO: move avatars to :settings hash, it makes more sense there
      :avatars => {
        :name => "User Avatars",
        :description => "",
        :default => false,
        :expose_to_ui => true
      }
    }.freeze
  end
  
  def self.default_allowable_services
    self.allowable_services.reject {|s, info| info[:default] == false }
  end
  
  def set_service_availability(service, enable)
    service = service.to_sym
    raise "Invalid Service" unless Account.allowable_services[service]
    allowed_service_names = (self.allowed_services || "").split(",").compact
    if allowed_service_names.count > 0 and not [ '+', '-' ].member?(allowed_service_names[0][0,1])
      # This account has a hard-coded list of services, so handle accordingly
      allowed_service_names.reject! { |flag| flag.match("^[+-]?#{service}$") }
      allowed_service_names << service if enable
    else
      allowed_service_names.reject! { |flag| flag.match("^[+-]?#{service}$") }
      if enable
        # only enable if it is not enabled by default
        allowed_service_names << "+#{service}" unless Account.default_allowable_services[service]
      else
        # only disable if it is not enabled by default
        allowed_service_names << "-#{service}" if Account.default_allowable_services[service]
      end
    end
    
    @allowed_services_hash = nil
    self.allowed_services = allowed_service_names.empty? ? nil : allowed_service_names.join(",")
  end
  
  def enable_service(service)
    set_service_availability(service, true)
  end
  
  def disable_service(service)
    set_service_availability(service, false)
  end
  
  def allowed_services_hash
    return @allowed_services_hash if @allowed_services_hash
    account_allowed_services = Account.default_allowable_services
    if self.allowed_services
      allowed_service_names = self.allowed_services.split(",").compact
      
      if allowed_service_names.count > 0
        unless [ '+', '-' ].member?(allowed_service_names[0][0,1])
          # This account has a hard-coded list of services, so we clear out the defaults
          account_allowed_services = { }
        end
        
        allowed_service_names.each do |service_switch|
          if service_switch =~ /\A([+-]?)(.*)\z/
            flag = $1
            service_name = $2.to_sym
            
            if flag == '-'
              account_allowed_services.delete(service_name)
            else
              account_allowed_services[service_name] = Account.allowable_services[service_name]
            end
          end
        end
      end
    end
    @allowed_services_hash = account_allowed_services
  end
  
  def self.services_exposed_to_ui_hash
    self.allowable_services.reject { |key, setting| !setting[:expose_to_ui] }
  end
  
  def service_enabled?(service)
    service = service.to_sym
    case service
    when :none
      self.allowed_services_hash.empty?
    else
      self.allowed_services_hash.has_key?(service)
    end
  end
  
  def self.all_accounts_for(context)
    if context.respond_to?(:account)
      context.account.account_chain
    elsif context.respond_to?(:parent_account)
      context.account_chain
    else
      []
    end
  end
  
  def self.serialization_excludes; [:uuid]; end
  
  # This could be much faster if we implement a SQL tree for the account tree
  # structure.
  def find_child(child_id)
    child_id = child_id.to_i
    child_ids = self.class.connection.select_values("SELECT id FROM accounts WHERE parent_account_id = #{self.id}").map(&:to_i)
    until child_ids.empty?
      if child_ids.include?(child_id)
        return self.class.find(child_id)
      end
      child_ids = self.class.connection.select_values("SELECT id FROM accounts WHERE parent_account_id IN (#{child_ids.join(",")})").map(&:to_i)
    end
    return false
  end

  def manually_created_courses_account
    (self.root_account || self).sub_accounts.find_or_create_by_name(t('#account.manually_created_courses', "Manually-Created Courses"))
  end

  def open_registration_for?(user, session = nil)
    root_account = self.root_account || self
    return true if root_account.open_registration?
    root_account.grants_right?(user, session, :manage_user_logins)
  end

  named_scope :sis_sub_accounts, lambda{|account, *sub_account_source_ids|
    {:conditions => {:root_account_id => account.id, :sis_source_id => sub_account_source_ids}, :order => :sis_source_id}
  }
  named_scope :root_accounts, lambda{
    {:conditions => {:root_account_id => nil} }
  }
  named_scope :needs_parent_account, lambda{|account, limit|
    {:conditions => {:parent_account_id => nil, :root_account_id => account.id}, :limit => limit }
  }
  named_scope :processing_sis_batch, lambda{ 
    {:conditions => ['accounts.current_sis_batch_id IS NOT NULL'], :order => :updated_at}
  }
  named_scope :name_like, lambda { |name|
    { :conditions => wildcard('accounts.name', name) }
  }
  named_scope :active, lambda {
    { :conditions => ['accounts.workflow_state != ?', 'deleted'] }
  }
  named_scope :limit, lambda {|limit|
    {:limit => limit}
  }
end
