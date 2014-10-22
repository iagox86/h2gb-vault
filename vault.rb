$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'binary'
require 'memory_abstraction'
require 'workspace'

require 'fileutils'
require 'json'
require 'tempfile'

require 'pp' # debug

# Database stuff
ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :host    => nil,
  :username => nil,
  :password => nil,
  :database => 'data.db',
  :encoding => 'utf8',
)

class VaultException < StandardError
end

class Vault < Sinatra::Application
#  set :environment, :production

  def add_status(status, table)
    table[:status] = status
    return table
  end

  def convert_num(n)
    if(n > 0xFFFF)
      return '0x%08x' % n
    elsif(n > 0xFF)
      return '0x%04x' % n
    elsif(n > 0)
      return '0x%02x' % n
    elsif(n == 0)
      return '0'
    else
      return "-%s" % (convert_num(n.abs()))
    end
  end

  def nested_elements(h)
    if(h.is_a?(Hash))
      h.each do |k, v|
        if(v.is_a?(Hash) || v.is_a?(Array))
          nested_elements(v) do |val|
            yield(val)
          end
        else
          h[k] = yield(v)
        end
      end
    elsif(h.is_a?(Array))
      h.each_index do |k|
        v = h[k]
        if(v.is_a?(Hash) || v.is_a?(Array))
          nested_elements(v) do |val|
            yield(val)
          end
        else
          h[k] = yield(v)
        end
      end
    end
  end

  def Vault.COMMAND(obj, action = nil)
    if(action.nil?)
      return /^\/#{obj}\/([a-fA-F0-9-]+)$/
    else
      return /^\/#{obj}\/([a-fA-F0-9-]+)\/#{action}$/
    end
  end

  # Add important headers and encode everything as JSON
  after do
    if(response.content_type.nil?)
      content_type 'application/json'
    end

    headers({ 'X-Frame-Options' => 'DENY' })

    if(response.content_type =~ /json/)
      headers({
        'Access-Control-Allow-Origin' => '*', # TODO: Might not need this forever
        'Content-Disposition' => 'Attachment'
      })

      nested_elements(response.body) do |e|
        value = e

        if(params['force_text'] && e.is_a?(Fixnum))
          value = ('0x%x' % e)
        elsif(e.is_a?(String))
          value = e.force_encoding('ISO-8859-1')
        end

        value # return
      end

      if(params['pretty'])
        response.body = JSON.pretty_generate(response.body) + "\n"
      else
        response.body = JSON.generate(response.body) + "\n"
      end

    end
  end

  # Handle errors (exceptions and stuff)
  error do
    status 500

    return add_status(500,  {:reason => env['sinatra.error'] })
  end

  # Handle file-not-found errors
  not_found do
    status 404

    return add_status(404, {:reason => 'not found' })
  end

  get('/') do
    return "Welcome to h2gb! If you don't know what to do, you probably don't need to be here. :)"
  end

  # TODO: I don't really think I need this anymore
  post('/binary/upload_html') do
    content_type 'text/html'

    b = Binary.new(
      :name => params['file'][:filename],
      :comment => params['comment'],
      :data => params['file'][:tempfile].read()
    )
    b.save()

    redirect to("/static/test.html##{b.id}")
  end

  post('/binary/upload') do
    body = JSON.parse(request.body.read, :symbolize_names => true)

    b = Binary.new(
      :name         => body[:name],
      :comment      => body[:comment],
      :data         => Base64.decode64(body[:data]),
    )
    b.save()

    return add_status(0, {:binary_id => b.id })
  end

  get('/binaries') do
    return add_status(0, {:binaries => Binary.all().as_json() })
  end

  get(COMMAND('binary', 'download')) do |binary_id|
    b = Binary.find(binary_id)
    return add_status(0, {
      :name    => b.name,
      :comment => b.comment,
      :data    => Base64.encode64(b.data),
    })
  end

  delete(COMMAND('binary')) do |binary_id|
    b = Binary.find(binary_id)
    b.destroy()

    return add_status(0, {})
  end

  post(COMMAND('binary', 'create_workspace')) do |binary_id|
    b = Binary.find(binary_id)

    w = b.workspaces.new(:name => params['name'])
    w.save()

    return add_status(0, {:workspace_id => w.id})
  end

  get(COMMAND('binary', 'workspaces')) do |binary_id|
    b = Binary.find(binary_id)

    return add_status(0, {:workspaces => b.workspaces.all().as_json() })
  end

  post(COMMAND('workspace', 'create_memory')) do |workspace_id|
    w = Workspace.find(workspace_id)

    ma = w.memory_abstractions.new(:name => params['name'])
    ma.save()

    return add_status(0, {:memory_id => ma.id})
  end

  get(COMMAND('workspace', 'get')) do |workspace_id|
    w = Workspace.find(workspace_id)
    name = params['name']

    return add_status(0, {:name => name, :value => w.get(name)})
  end

  post(COMMAND('workspace', 'set')) do |workspace_id|
    body = JSON.parse(request.body.read, :symbolize_names => true)

    w = Workspace.find(workspace_id)

    # Make sure it's an array
    if(body.is_a?(Hash))
      body = [body]
    end

    # Make sure the body is sane
    if(!body.is_a?(Array))
      raise(VaultException, "The 'set' command requires an hash (or an array of hashes) containing 'name' and 'value' fields")
    end

    # Loop through the body
    body.each do |kv|
      name  = kv[:name]
      value = kv[:value]

      # Make sure we have a sane name
      if(!name.is_a?(String))
        raise(VaultException, "The 'set' command requires a hash (or an array of hashes) containing 'name' and 'value' fields")
      end

      puts("Setting %s => %s" % [name, value.to_s])
      w.set(name, value)
    end
    w.save()

    return add_status(0, {})
  end

  delete(COMMAND('workspace')) do |workspace_id|
    w = Workspace.find(workspace_id)
    w.destroy()

    return add_status(0, {})
  end

  get(COMMAND('workspace')) do |workspace_id|
    w = Workspace.find(workspace_id)

    return add_status(0, {:settings => w.settings})
  end

  def memory_response(ma, params, p = {})
    starting = (params['starting'] || ma.starting_revision || 0).to_i()

    if(p[:only_nodes])
      return {:revision => ma.revision(), :nodes => ma.nodes(starting)}
    elsif(p[:only_segments])
      return {:revision => ma.revision(), :segments => ma.segments(starting)}
    else
      return {:revision => ma.revision(), :memory => ma.state(starting)}
    end
  end

  post(COMMAND('memory', 'do_delta')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    delta = JSON.parse(params['delta'], :symbolize_names => true)
    ma.do_delta(delta)
    ma.save()

    return add_status(0, memory_response(ma, params))
  end
  post(COMMAND('memory', 'create_segment')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    body = JSON.parse(request.body.read, :symbolize_names => true)
    if(body[:segment].nil?)
      pp body
      raise(VaultException, "Required field: 'segment'.")
    end

    # Make sure it's an array
    segments = body[:segment]
    if(segments.is_a?(Hash))
      segments = [segments]
    end

    # Loop through the one or more segments we need to create and do them
    segments.each do |segment|
      if(!segment[:data].is_a?(String))
        raise(VaultException, "Segments require a base64-encoded 'data' field")
      end
      segment[:data] = Base64.decode64(segment[:data])
      ma.do_delta(ma.create_segment_delta(segment))
    end
    ma.save()

    return add_status(0, memory_response(ma, params))
  end

  post(COMMAND('memory', 'delete_segment')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    segments = JSON.parse(params['segment'], :symbolize_names => true)

    # If it's just a string, make it into an array
    if(segments.is_a?(String))
      segments = [segments]
    end

    # If it isn't an array, we have problems
    if(!segments.is_a?(Array))
      raise(VaultException, "delete_segment requires one or more names as the body")
    end

    # Loop through the one or more segments we need to create and do them
    segments.each do |segment|
      ma.do_delta(ma.delete_segment_delta(segment))
    end
    ma.save()

    return add_status(0, memory_response(ma, params))
  end

  post(COMMAND('memory', 'create_node')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    body = JSON.parse(request.body.read, :symbolize_names => true)
    if(body[:node].nil?)
      pp body
      raise(VaultException, "Required field: 'node'.")
    end

    # Make sure it's an array
    nodes = body[:node]
    if(nodes.is_a?(Hash))
      nodes = [nodes]
    end

    # Loop through the one or more nodes we need to create and do them
    nodes.each do |node|
      ma.do_delta(ma.create_node_delta(node))
    end
    ma.save()

    return add_status(0, memory_response(ma, params))
  end

  post(COMMAND('memory', 'delete_node')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    nodes = JSON.parse(params['node'], :symbolize_names => true)

    # If it's just a string, make it into an array
    if(nodes.is_a?(Fixnum))
      nodes = [nodes]
    end

    # If it isn't an array, we have problems
    if(!nodes.is_a?(Array))
      raise(VaultException, "delete_node requires one or more names as the body")
    end

    # Loop through the one or more nodes we need to create and do them
    nodes.each do |node|
      if(!node.is_a?(Fixnum))
        raise(VaultException, "delete_node requires a single or an array of addresses as integers")
      end
      ma.do_delta(ma.delete_node_delta(node))
    end
    ma.save()

    return add_status(0, memory_response(ma, params))
  end

  #puts m.do_delta(ma.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x1004]}))

  post(COMMAND('memory', 'undo')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    ma.undo()
    ma.save()

    return add_status(0, memory_response(ma, params))
  end

  get(COMMAND('memory')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    return add_status(0, memory_response(ma, params))
  end

  get(COMMAND('memory', 'segments')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    return add_status(0, memory_response(ma, params, :only_segments => true))
  end

  get(COMMAND('memory', 'nodes')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    return add_status(0, memory_response(ma, params, :only_nodes => true))
  end

  delete(COMMAND('memory')) do |memory_id|
    b = MemoryAbstraction.find(memory_id)
    b.destroy()

    return add_status(0, {})
  end

  # TODO: This is testing only
  get(COMMAND('memory', 'clear')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    ma.deltas = []
    ma.undo_buffer = []
    ma.redo_buffer = []
    ma.save()

    return add_status(0, {:result => "Done!"})

  end

  get(/\/static\/([a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+)/) do |file|
    if(file =~ /\.html$/)
      content_type "text/html"
    elsif(file =~ /\.js$/)
      content_type "text/javascript"
    else
      raise(Exception, "Unknown filetype")
    end

    return IO.read(File.dirname(__FILE__) + "/static/#{file}")
  end
end
