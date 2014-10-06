$LOAD_PATH << File.dirname(__FILE__)

require 'models/binary'
require 'models/project'
require 'models/delta'

# Database stuff
ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :host    => nil,
  :username => nil,
  :password => nil,
  :database => 'data.db',
  :encoding => 'utf8',
)

b = Binary.new(
  :name    => "test",
  :comment => "automatically created",
  :data    => File.new("/home/ron/Desktop/sample.raw", "rb").read()
)
b.save()

p = b.projects.new(
  :binary => b,
)
p.save()

t = p.deltas.new(
  :deltas => [
    { :type => "change_type", :offset => 0, :length => 1, :newtype => "dword" },
    { :type => "change_type", :offset => 4, :length => 1, :newtype => "dword" },
    { :type => "change_type", :offset => 8, :length => 1, :newtype => "dword" },
  ]
)
t.save()

puts(p.get_current_view())
