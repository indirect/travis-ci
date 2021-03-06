require 'uri'

RSpec::Matchers.define :have_last_build do |build|
  match do |repository|
    repository.last_build_id.should == build.id
    repository.last_build_status.should == build.status
    repository.last_build_started_at.should == build.started_at
    repository.last_build_finished_at.should == build.finished_at
  end
end

RSpec::Matchers.define :send_email_notification_on do |event|
  match do |build|
    dispatch =  lambda { Travis::Notifications.dispatch(event, build) }
    dispatch.should change(ActionMailer::Base.deliveries, :size).by(1)
    ActionMailer::Base.deliveries.last
  end
end

RSpec::Matchers.define :post_webhooks_on do |event, object, options|
  match do |dispatch|
    options[:to].each { |url| expect_request(url, object) }
    dispatch.call(event, object)
  end

  def expect_request(url, object)
    uri = URI.parse(url)
    $http_stub.post uri.path do |env|
      env[:url].host.should == uri.host
      env[:url].path.should == uri.path
      env[:request_headers]['Authorization'].should == authorization_for(object)

      payload = normalize_json(Travis::Notifications::Webhook::Payload.new(object).to_hash)
      payload_from(env).keys.sort.should == payload.keys.map(&:to_s).sort
    end
  end

  def payload_from(env)
    JSON.parse(Rack::Utils.parse_query(env[:body])['payload'])
  end

  def authorization_for(object)
    Travis::Notifications::Webhook.new.send(:authorization, object)
  end
end

RSpec::Matchers.define :serve_status_image do |status|
  match do |request|
    path = "#{Rails.root}/app/assets/status/#{status}.png"
    controller.expects(:send_file).with(path, { :type => 'image/png', :disposition => 'inline' }).once
    request.call
  end
end

RSpec::Matchers.define :have_body_text do |text|
  match do |email|
    description { "have the expected body text" }

    body = email.parts.last.body.to_s
    lines = text.split("\n").map(&:strip).inject([]) do |lines, line|
      lines << "  #{line}" if line.present? && !body.include?(line)
      lines
    end

    failure_message_for_should { "The email body was expected to contain the following lines but didn't:\n\n#{lines.join("\n")}\n\nActual body: #{body}" }
    failure_message_for_should_not { "The email body was expected to not contain the following lines but did:\n\n#{lines.join("\n")}\n\nActual body: #{body}" }

    lines.empty?
  end
end

RSpec::Matchers.define :have_subject do |subject|
  match do |email|
    description { "have subject of #{subject.inspect}" }
    failure_message_for_should { "expected the subject to be #{subject.inspect} but was #{email.subject.inspect}" }
    failure_message_for_should_not { "expected the subject not to be #{subject.inspect} but was" }

    email.subject == subject
  end
end

RSpec::Matchers.define :deliver_to do |expected|
  match do |email|
    actual = (email.header[:to].addrs || []).map(&:to_s)

    description { "be delivered to #{expected.inspect}" }
    failure_message_for_should { "expected #{email.inspect} to deliver to #{expected.inspect}, but it delivered to #{actual.inspect}" }
    failure_message_for_should_not { "expected #{email.inspect} not to deliver to #{expected.inspect}, but it did" }

    actual.sort == expected.sort
  end
end


RSpec::Matchers.define :have_message do |event|
  match do |pusher|
    @event = event

    description { "have a message #{event.inspect}" }
    failure_message_for_should { "expected pusher to receive #{event.inspect} but it did not. Instead it has the following messages: #{pusher.messages.map(&:first).map(&:inspect).join(', ')}" }
    failure_message_for_should_not { "expected pusher not to receive #{event.inspect} but it did" }

    !!find_message.tap { |message| pusher.messages.delete(message) }
  end

  def find_message
    pusher.messages.detect { |message| message.first == @event }
  end
end

RSpec::Matchers.define :be_queued do |*args|
  match do |task|
    @options = args.last.is_a?(Hash) ? args.pop : {}
    @queue = args.first || @options[:queue] || 'builds'
    @task = task
    @expected = task.is_a?(Task) ? Travis::Notifications::Worker.payload_for(@task, :queue => 'builds') : task
    @actual = job ? job['args'].last.deep_symbolize_keys : nil

    Resque.pop(@queue) if @options[:pop]
    @actual == @expected
  end

  def job
    @job ||= Resque.peek(@queue, 0, 50).detect { |job| job['args'].last.deep_symbolize_keys == @expected.deep_symbolize_keys }
  end

  def jobs
    Resque.peek(@queue, 0, 50).map { |job| job.inspect }.join("\n")
  end

  failure_message_for_should do
    @actual ?
      "expected the job queued in #{@queue.inspect} to have the payload #{@actual.inspect} but had #{@expected.inspect}" :
      "expected a job with the payload #{@expected.inspect} to be queued in #{@queue.inspect} but none was found. Instead there are the following jobs:\n\n#{jobs}"
  end

  failure_message_for_should_not do
    @actual ?
      "expected the job queued in #{@queue.inspect} not to have #{@actual.inspect} but it has" :
      "expected no job with the payload #{@expected.inspect} to be queued in #{@queue.inspect} but it is"
  end
end
