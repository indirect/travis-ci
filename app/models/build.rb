require 'core_ext/active_record/base'

class Build < ActiveRecord::Base
  include Matrix, Notifications, SimpleStates, Travis::Notifications

  PER_PAGE = 10

  states :created, :started, :finished

  event :start,  :to => :started
  event :finish, :to => :finished, :if => :matrix_finished?
  event :all, :after => :denormalize # TODO bug in simple_states. should be able to pass an array

  belongs_to :commit
  belongs_to :request
  belongs_to :repository, :autosave => true
  has_many   :matrix, :as => :owner, :order => :id, :class_name => 'Task::Test'

  # validates :repository_id, :commit_id, :request_id, :presence => true

  serialize :config

  class << self
    def recent(options = {})
      was_started.descending.paged(options).includes([:commit, { :matrix => :commit }])
    end

    def was_started
      where(:state => ['started', 'finished'])
    end

    def finished
      where(:state => 'finished')
    end

    def on_branch(branches)
      branches = Array(branches.try(:split, ',')).compact.join(',').split(',')
      joins(:commit).where(branches.present? ? ["commits.branch IN (?)", branches] : [])
    end

    def last_finished_on_branch(branches)
      finished.on_branch(branches).descending.first
    end

    def descending
      order(arel_table[:id].desc)
    end

    def paged(options)
      # TODO should use an offset when we use limit!
      # offset(PER_PAGE * options[:offset]).limit(options[:page])
      limit(PER_PAGE * (options[:page] || 1).to_i)
    end

    def next_number
      maximum(floor('number')).to_i + 1
    end
  end

  after_initialize do
    self.config = {} if config.nil?
  end

  before_create do
    self.number = repository.builds.next_number
    expand_matrix
  end

  def config=(config)
    super(config.deep_symbolize_keys)
  end

  def start(data = {})
    self.started_at = data[:started_at]
  end

  def finish(data = {})
    self.status = matrix_status
    self.finished_at = data[:finished_at]
  end

  def pending?
    !finished?
  end

  def passed?
    status == 0
  end

  def failed?
    !passed?
  end

  def status_message
    pending? ? 'Pending' : passed? ? 'Passed' : 'Failed'
  end

  def color
    pending? ? 'yellow' : passed? ? 'green' : 'red'
  end

  protected

    def denormalize(*args)
      event = args.first # TODO bug in simple_state? getting an error when i add this to the method signature
      repository.update_attributes!(denormalize_attributes_for(event)) # if denormalize?(event)
      notify(*args)
    end

    DENORMALIZE = {
      :start  => %w(id number status started_at finished_at),
      :finish => %w(status finished_at)
    }

    def denormalize?(event)
      DENORMALIZE.key?(event)
    end

    def denormalize_attributes_for(event)
      DENORMALIZE[event].inject({}) do |result, key|
        result.merge(:"last_build_#{key}" => send(key))
      end
    end
end
