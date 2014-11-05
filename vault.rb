$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'models/binary'
require 'models/view'
require 'models/workspace'

require 'json'

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

  # Create a binary
  post('/binaries') do
    body = JSON.parse(request.body.read, :symbolize_names => true)

    b = Binary.new(
      :name         => body[:name],
      :comment      => body[:comment],
      :data         => Base64.decode64(body[:data]),
    )
    b.save()

    return b.to_json()
  end

  # List binaries (note: doesn't return file contents)
  # TODO: This should return :binary_id properly
  get('/binaries') do
    return {:binaries => Binary.all_to_json() }
  end

  # Download a binary
  get('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    return b.to_json()
  end

  # Update binary
  put('/binaries/:binary_id') do |binary_id|
    body = JSON.parse(request.body.read, :symbolize_names => true)

    b = Binary.find(binary_id)
    b.name = body[:name]
    b.comment = body[:comment]
    b.data = Base64.decode64(body[:data])
    b.save()

    return b.to_json()
  end

  # Delete binary
  delete('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    b.destroy()

    return {:deleted => true}
  end

  post('/binaries/:binary_id/new_workspace') do |binary_id|
    body = JSON.parse(request.body.read, :symbolize_names => true)

    b = Binary.find(binary_id)
    w = b.workspaces.new(:name => body[:name])
    w.save()

    return w.to_json()
  end

  get('/binaries/:binary_id/workspaces') do |binary_id|
    b = Binary.find(binary_id)

    return {:workspaces => Workspace.all_to_json(b.workspaces.all()) }
  end

  # Get info about a workspace
  get('/workspaces/:workspace_id') do |workspace_id|
    w = Workspace.find(workspace_id)

    return w.to_json()
  end

  # Update workspace
  put('/workspaces/:workspace_id') do |workspace_id|
    body = JSON.parse(request.body.read, :symbolize_names => true)

    w = Workspace.find(workspace_id)
    w.name = body[:name]
    w.save()

    return w.to_json()
  end

  delete('/workspaces/:workspace_id') do |workspace_id|
    w = Workspace.find(workspace_id)
    w.destroy()

    return {:deleted => true}
  end

  # Get setting
  get('/workspaces/:workspace_id/get') do |workspace_id|
    w = Workspace.find(workspace_id)
    name = params['name']

    # TODO: Rename this to key/value to be less confusing
    return add_status(0, {:name => name, :value => w.get(name)})
  end

  # Set setting
  post('/workspaces/:workspace_id/set') do |workspace_id|
    body = JSON.parse(request.body.read, :symbolize_names => true)

    puts(body.inspect)

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

  # Create view
  post('/workspaces/:workspace_id/new_view') do |workspace_id|
    w = Workspace.find(workspace_id)

    ma = w.views.new(:name => params['name'])
    ma.save()

    return add_status(0, {:view_id => ma.id})
  end

  # Get views for a workspace
  get('/workspaces/:workspace_id/views') do |workspace_id|
    w = Workspace.find(workspace_id)

    return add_status(0, {:views => w.views.all().as_json() })
  end

  # Find view
  get('/views/:view_id') do |view_id|
    ma = View.find(view_id)

    return add_status(0, view_response(ma, params))
  end

  # Update view
  # TODO: Make sure this is being tested
  put('/views/:view_id') do |view_id|
    body = JSON.parse(request.body.read, :symbolize_names => true)

    v = view.find(view_id)
    v.name = body[:name]
    v.save()

    return add_status(0, {:view_id => v.id, :name => v.name})
  end

  # Delete view
  delete('/views/:view_id') do |view_id|
    b = View.find(view_id)
    b.destroy()

    return add_status(0, {})
  end

  # TODO: This should be moved into the View class
  def view_response(ma, params, p = {})
    starting = (params['starting'] || ma.starting_revision || 0).to_i()

    if(p[:only_nodes])
      return {:view_id => ma.id, :revision => ma.revision(), :nodes => ma.nodes(starting)}
    elsif(p[:only_segments])
      return {:view_id => ma.id, :revision => ma.revision(), :segments => ma.segments(starting)}
    else
      return {:view_id => ma.id, :revision => ma.revision(), :view => ma.state(starting)}
    end
  end

  post('/views/:view_id/new_segment') do |view_id|
    ma = View.find(view_id)

    body = JSON.parse(request.body.read, :symbolize_names => true)
    if(body[:segment].nil?)
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

    return add_status(0, view_response(ma, params))
  end

  post('/views/:view_id/delete_segment') do |view_id|
    ma = View.find(view_id)
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

    return add_status(0, view_response(ma, params))
  end

  post('/views/:view_id/new_node') do |view_id|
    ma = View.find(view_id)

    body = JSON.parse(request.body.read, :symbolize_names => true)
    if(body[:node].nil?)
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

    return add_status(0, view_response(ma, params))
  end

  post('/views/:view_id/delete_node') do |view_id|
    ma = View.find(view_id)
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

    return add_status(0, view_response(ma, params))
  end

  #puts m.do_delta(ma.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x1004]}))

  post('/views/:view_id/undo') do |view_id|
    ma = View.find(view_id)
    ma.undo()
    ma.save()

    return add_status(0, view_response(ma, params))
  end

  get('/views/:view_id/segments') do |view_id|
    ma = View.find(view_id)

    return add_status(0, view_response(ma, params, :only_segments => true))
  end

  get('/views/:view_id/nodes') do |view_id|
    ma = View.find(view_id)

    return add_status(0, view_response(ma, params, :only_nodes => true))
  end

  # TODO: This is testing only
  get('/views/:view_id/clear') do |view_id|
    ma = View.find(view_id)
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
