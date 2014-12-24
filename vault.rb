$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'models/binary'
require 'models/workspace'

require 'json'

require 'pp' # TODO: DEBUG

# Disable verbose logging

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
  set :environment, :production

  def add_status(status, table)
    table[:status] = status
    return table
  end

  def to_a(d)
    if(d.is_a?(Array))
      return d
    end
    return [d]
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

  before do
    # Turn down the logging
    ActiveRecord::Base.logger.sev_threshold = Logger::WARN
  end

  before do
    # Do an ugly check to see if we're using a version of Sinatra that doesn't expose the params
    begin
      if(params.nil?)
        raise(VaultException, "Control-flow exceptions are bad")
      end
    rescue
      raise(VaultException, "It looks like there's a problem in the before() function, updating Sinatra will likely fix it")
    end

    # Truthify the parameters
    result = {}
    params.each_pair do |k, v|
      if(v == '')
        v = nil
      elsif(v == 'true')
        v = true
      elsif(v == 'false')
        v = false
      elsif(v =~ /^[0-9]+$/)
        v = v.to_i()
      end

      result[k.to_sym] = v
    end

    # Clear out all other parameters
    params.clear()

    # Merge in the fixed ones
    params.merge!(result)

    # Merge in body parameters if they're present
    if(request.body.present?)
      body = request.body.read()

      if(body.length > 0)
        # This is ugly hacks to get around a bug in rack
        if(body =~ /^BASE64/)
          body = Base64.decode64(body[6..-1])
        end

        params.merge!(JSON.parse(body, :symbolize_names => true))
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

      response.body = JSON.pretty_generate(response.body) + "\n"

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

  post('/binaries') do
    b = Binary.new(
      :name         => params.delete(:name),
      :comment      => params.delete(:comment),
      :data         => Base64.decode64(params.delete(:data)),
    )
    b.save()

    return b.to_json(params)
  end

  get('/binaries') do
    return {:binaries => Binary.all_to_json(params) }
  end

  get('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    return b.to_json(params)
  end

  put('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    if(!params[:name].nil?)
      b.name = params.delete(:name)
    end

    if(!params[:comment].nil?)
      b.comment = params.delete(:comment)
    end

    if(!params[:data].nil?)
      b.data = Base64.decode64(params.delete(:data))
    end
    b.save()

    return b.to_json(params)
  end

  delete('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    b.destroy()

    return {:deleted => true}
  end

  post('/binaries/:binary_id/set_properties') do |binary_id|
    b = Binary.find(binary_id)

    properties = params.delete(:properties)
    if(!properties.is_a?(Hash))
      raise(VaultException, "The :properties parameter is mandatory, and must be a hash")
    end

    b.set_properties(properties)
    b.save()

    return b.to_json(params)
  end

  post('/binaries/:binary_id/get_properties') do |binary_id|
    b = Binary.find(binary_id)
    keys = params.delete(:keys)
    result = b.get_properties(keys)
    return result
  end

  # Create workspace
  post('/binaries/:binary_id/new_workspace') do |binary_id|
    b = Binary.find(binary_id)

    workspace = b.workspaces.new(:name => params.delete(:name))
    workspace.save()

    return workspace.to_json(params)
  end

  # Get workspaces for a binary
  get('/binaries/:binary_id/workspaces') do |binary_id|
    b = Binary.find(binary_id)

    return {
      :workspaces => Workspace.all_to_json({
        :all => b.workspaces.all()
      }.merge(params)
    )}
  end

  # Find workspace
  get('/workspaces/:workspace_id') do |workspace_id|
    v = Workspace.find(workspace_id)

    return v.to_json({
      :with_segments => false, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
    }.merge(params))
  end

  # Update workspace
  # TODO: Make sure this is being tested
  put('/workspaces/:workspace_id') do |workspace_id|
    v = Workspace.find(workspace_id)
    v.name = params[:name]
    v.save()

    return v.to_json({
      :with_segments => false, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
    }.merge(params))
  end

  # Delete workspace
  delete('/workspaces/:workspace_id') do |workspace_id|
    v = Workspace.find(workspace_id)
    v.destroy()

    return {:deleted => true}
  end

  post('/workspaces/:workspace_id/set_properties') do |workspace_id|
    v = Workspace.find(workspace_id)

    properties = params.delete(:properties)
    if(!properties.is_a?(Hash))
      raise(VaultException, "The :properties parameter is mandatory, and must be a hash")
    end

    v.set_properties(properties)
    v.save()

    return v.to_json(params)
  end

  post('/workspaces/:workspace_id/get_properties') do |workspace_id|
    v = Workspace.find(workspace_id)
    keys = params.delete(:keys)
    result = v.get_properties(keys)
    return result
  end

  post('/workspaces/:workspace_id/new_segments') do |workspace_id|
    workspace = Workspace.find(workspace_id)

    # Convert the segment names to strings instead of symbols
    segments = params.delete(:segments)
    segments.each do |segment|
      segment[:data] = Base64.decode64(segment[:data])
    end

    # Loop through the one or more segments we need to create and do them
    workspace.create_segments(segments)
    workspace.save()

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
      :since         => workspace.starting_revision,
    }.merge(params))
  end

  post('/workspaces/:workspace_id/delete_segments') do |workspace_id|
    workspace = Workspace.find(workspace_id)
    segments = params[:segments]

    # Delete the segments
    workspace.delete_segments(segments)
    workspace.save()

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
      :since         => workspace.starting_revision,
    }.merge(params))
  end

  post('/workspaces/:workspace_id/delete_all_segments') do |workspace_id|
    workspace = Workspace.find(workspace_id)
    workspace.delete_all_segments()
    workspace.save()

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
      :since         => workspace.starting_revision,
    }.merge(params))
  end

  post('/workspaces/:workspace_id/new_nodes') do |workspace_id|
    workspace = Workspace.find(workspace_id)

    if(params[:nodes].nil?)
      raise(VaultException, "Required field: 'nodes'.")
    end
    if(params[:segment].nil?)
      raise(VaultException, "Required field: 'segment'.")
    end

    workspace.create_nodes(
      :segment_name => params[:segment],
      :nodes        => params[:nodes],
    )
    workspace.save()

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => workspace.starting_revision,
    }.merge(params))
  end

  post('/workspaces/:workspace_id/delete_nodes') do |workspace_id|
    workspace = Workspace.find(workspace_id)
    segment_name = params[:segment]
    addresses = params[:addresses]
    workspace.delete_nodes({
      :segment_name => segment_name,
      :addresses    =>addresses
    })
    workspace.save()

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => workspace.starting_revision,
    }.merge(params))
  end

  post('/workspaces/:workspace_id/undo') do |workspace_id|
    workspace = Workspace.find(workspace_id)
    workspace.undo(params)
    workspace.save()

    result = workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => workspace.starting_revision,
    }.merge(params))

    return result
  end

  post('/workspaces/:workspace_id/clear_undo_log') do |workspace_id|
    workspace = Workspace.find(workspace_id)
    workspace.clear_undo_log()
    workspace.save()

    result = workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => workspace.starting_revision,
    }.merge(params))

    return result
  end

  post('/workspaces/:workspace_id/redo') do |workspace_id|
    workspace = Workspace.find(workspace_id)
    workspace.redo(params)
    workspace.save()

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => workspace.starting_revision,
    }.merge(params))
  end

  get('/workspaces/:workspace_id/segments') do |workspace_id|
    workspace = Workspace.find(workspace_id)

    if(params[:with_data].nil?)
      params
    end
    if(params[:with_nodes].nil?)
      params[:with_nodes] = false
    end

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
    }.merge(params))
  end

  get('/workspaces/:workspace_id/nodes') do |workspace_id|
    workspace = Workspace.find(workspace_id)

    return workspace.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
    }.merge(params))
  end

  get('/workspaces/:workspace_id/debug/undo_log') do |workspace_id|
    workspace = Workspace.find(workspace_id)

    return workspace.undo_to_json()
  end
end
