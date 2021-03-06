Before do
  @goliaths = {}
  @config = Pontoon::Config.new(
      Pontoon::Goliath.rpc_provider(Proc.new {|node_id, message| URI("http://localhost:#{node_id}/#{message}")}),
      Pontoon::Goliath.async_provider,
      1.5, #election_timeout seconds
      1.0, #election_splay seconds
      0.2, #update_interval seconds
      1.0) #heartbeat_interval second
  @cluster = Pontoon::Cluster.new
end

After do
  @goliaths.values.each {|goliath| goliath.stop}
  EventMachine.stop
end

def create_node_on_port(port)
  @cluster.node_ids << port
  node = Pontoon::Node.new(port, @config, @cluster)
  @goliaths[port] = Pontoon::Goliath.new(node) {|command| puts "executing command #{command}"}
  @goliaths[port].start(port: port)
end

def role_code(role)
  case role
  when /leader/i
    Pontoon::Node::LEADER_ROLE
  when /follower/i
    Pontoon::Node::FOLLOWER_ROLE
  when /candidate/i
    Pontoon::Node::CANDIDATE_ROLE
  end
end

def clear_log_on_node(node)
  log = node.persistent_state.log
  log.clear if log.any?
end

def update_log_on_node(node, new_log)
  clear_log_on_node(node)
  log = node.persistent_state.log
  new_log.each {|log_entry| log << log_entry}
end

def consistent_logs?
  first_node = @goliaths.values.first.node
  @goliaths.values.map(&:node).all? do |node|
    cons = first_node.persistent_state.log == node.persistent_state.log
    cons &&= first_node.temporary_state.commit_index == node.temporary_state.commit_index
    cons && first_node.temporary_state.commit_index == first_node.persistent_state.log.last.index
  end
end

Given(/^there is a node on port (\d+)$/) do |port|
  create_node_on_port(port)
end

When(/^I send the command "(.*?)" to the node on port (\d+)$/) do |command, port|
  http = EventMachine::HttpRequest.new("http://localhost:#{port}/command").apost(
      :body => %Q({"command": "#{command}"}),
      :head => { 'Content-Type' => 'application/json' })
  http.timeout 10
  http.errback {|*args| fail "request error"}#": #{http.pretty_inspect}\n\nnodes: #{@goliaths.values.map {|g|g.node}.pretty_inspect}"}
  #puts "EM.threadpool.count:#{EM.threadpool.count}"
  EM::Synchrony.sync(http)
  #puts "EM.threadpool.count:#{EM.threadpool.count}"
  #fail "request invalid" if http.nil?
  fail "request unfinished: #{http}" unless http.finished?
  #fail "request unfinished (http = #{http.pretty_inspect})" unless http.finished?
end

Then(/^the node on port (\d+) should be in the "(.*?)" role$/) do |port, role|
  @goliaths[port].node.role.should == role_code(role)
end

Given(/^there are nodes on the following ports:$/) do |table|
  table.raw.each do |row|
    create_node_on_port(row[0])
  end
end

Then(/^just one of the nodes should be in the "(.*?)" role$/) do |role|
  @goliaths.values.select {|goliath| goliath.node.role == role_code(role)}
end

Given(/^all the nodes have empty logs$/) do
  @goliaths.values.each do |goliath|
    clear_log_on_node(goliath.node)
  end
end

Given(/^the node on port (\d+) has an empty log$/) do |port|
  clear_log_on_node(@goliaths[port].node)
end

Given(/^the node on port (\d+) has the following log:$/) do |port, table|
  log = table.hashes.map {|row| Pontoon::LogEntry.new(row['term'].to_i, row['index'].to_i, row['command'])}.to_a
  update_log_on_node(@goliaths[port].node, log)
end

Given(/^the node on port (\d+)'s current term is (\d+)$/) do |port, term|
  @goliaths[port].node.persistent_state.current_term = term.to_i
end

Then(/^a single node on one of the following ports should be in the "(.*?)" role:$/) do |role, table|
  begin
    table.raw.map {|row| row[0]}.select {|port| @goliaths[port].node.role == role_code(role)}.should have(1).item
  rescue
    @goliaths.values.map(&:node).each {|node| puts "Node #{node.id}: role #{node.role}"}
    raise
  end
end

Then(/^the node on port (\d+) should have the following log:$/) do |port, table|
  log = table.hashes.map {|row| Pontoon::LogEntry.new(row['term'].to_i, row['index'].to_i, row['command'])}.to_a
  @goliaths[port].node.persistent_state.log.should == log
end

Then(/^the node on port (\d+) should have the following commands in the log:$/) do |port, table|
  commands = table.raw.map(&:first)
  @goliaths[port].node.persistent_state.log.map(&:command).should == commands
end

When(/^I await full replication$/) do
  f = Fiber.current

  # Allow up to 10 seconds
  timeout_timer = EventMachine.add_timer(10) do
    f.resume
  end

  # Check every 1 second
  check_timer = EventMachine.add_periodic_timer(1) do
    if consistent_logs?
      f.resume
    end
  end

  Fiber.yield

  EventMachine.cancel_timer(check_timer)
  EventMachine.cancel_timer(timeout_timer)
end

Given(/^the node port port (\d+) has as commit index of (\d+)$/) do |port, commit_index|
  @goliaths[port].node.temporary_state.commit_index = commit_index.to_i
end
