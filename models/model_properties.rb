# model_properties.rb
# Created on November 30, 2014
# By Ron Bowes

module ModelProperties
  def self.included(o)
    # TODO
    #self.properties ||= {}
  end

  def set_property(k, v)
    if(v.nil?)
      self.properties.delete(k.to_sym())
    else
      self.properties[k.to_sym()] = v
    end
  end

  def get_property(k)
    return self.properties[k.to_sym]
  end

  def set_properties(hash)
    hash.each_pair do |k, v|
      set_property(k, v)
    end
  end

  # TODO: This isn't implemented super efficiently
  def get_properties(keys)
    if(keys.nil?)
      keys = self.properties.keys
    end

    result = {}
    keys.each do |k|
      result[k] = get_property(k.to_sym)
    end

    return result
  end

  def clear_properties()
    self.properties.clear
  end
end
