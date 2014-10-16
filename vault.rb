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

class Vault < Sinatra::Application
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

  def convert_to_text!(h)
    if(h.is_a?(Hash))
      h.each do |k, v|
        if(v.is_a?(Fixnum))
          h[k] = convert_num(v)
        elsif(v.is_a?(Hash) || v.is_a?(Array))
          convert_to_text!(v)
        end
      end
    elsif(h.is_a?(Array))
      h.each_index do |k|
        v = h[k]
        if(v.is_a?(Fixnum))
          h[k] = convert_num(v)
        elsif(v.is_a?(Hash) || v.is_a?(Array))
          convert_to_text!(v)
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

      if(params['force_text'])
        convert_to_text!(response.body)
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

  get '/' do
    return "Welcome to h2gb!"
  end

  post '/upload_html' do
    content_type 'text/html'

    b = Binary.new(
      :name => params['file'][:filename],
      :comment => params['comment'],
      :data => params['file'][:tempfile].read()
    )
    b.save()


    redirect to("/static/test.html##{b.id}")
  end

  post '/upload' do
    b = Binary.new(
      :name         => params['filename'],
      :comment      => params['comment'],
      :data         => params['data'],
      :is_processed => false,
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
      :command => b.comment,
      :file    => Base64.encode64(b.data),
    })
  end

  get(COMMAND('binary', 'delete')) do |binary_id|
    b = Binary.find(binary_id)
    b.destroy()

    return add_status(0, {})
  end

  get(COMMAND('binary', 'create_workspace')) do |binary_id|
    b = Binary.find(binary_id)

    w = b.workspaces.new(:name => params['name'])
    w.save()

    return add_status(0, {:workspace_id => w.id})
  end

  get(COMMAND('workspace', 'create_memory')) do |workspace_id|
    w = Workspace.find(workspace_id)

    ma = w.memory_abstractions.new(:name => params['name'])
    ma.save()

    return add_status(0, {:memory_id => ma.id})
  end

  get(COMMAND('workspace', 'get')) do |workspace_id|
    w = Workspace.find(workspace_id)
    name = params['name']

    return add_status(0, {:value => w.get(name)})
  end

  get(COMMAND('workspace', 'set')) do |workspace_id|
    w = Workspace.find(workspace_id)
    name = params['name']
    value = params['value']

    w.set(name, value)
    w.save()

    return add_status(0, {})
  end

  post(COMMAND('memory', 'do_delta')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    deltas = params['delta']

    if(deltas.is_a?(Array))
      deltas.each do |delta|
        ma.apply_delta(delta)
      end
    else
      ma.apply_delta(deltas)
    end
    ma.save()

    # TODO: Return the changed nodes
    return add_status(0, {:memory_abstraction => ma.get_nodes()})
  end

  get(COMMAND('memory', 'undo')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)
    ma.undo()
    ma.save()
  end

  get(COMMAND('memory', 'segments')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    return add_status(0, {:segments => ma.segments()})
  end

  get(COMMAND('memory', 'nodes')) do |memory_id|
    ma = MemoryAbstraction.find(memory_id)

    return add_status(0, {:nodes => ma.nodes()})
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
