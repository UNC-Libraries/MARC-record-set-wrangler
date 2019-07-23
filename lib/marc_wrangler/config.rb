module MarcWrangler
  module Config
    def self.get_fields_by_spec(fields, spec)
      acc = []
      spec.each do |fspec|
        tmpfields = fields.select { |f| f.tag =~ /#{fspec['tag']}/ }
        if fspec.key?('i1')
          tmpfields.select! { |f| f.indicator1 =~ /#{fspec['i1']}/ }
        end
        if fspec.key?('i2')
          tmpfields.select! { |f| f.indicator2 =~ /#{fspec['i2']}/ }
        end
        if fspec.key?('field has')
          tmpfields.select! { |f| f.to_s =~ /#{fspec['field has']}/i }
        end
        if fspec.key?('field does not have')
          tmpfields.reject! { |f| f.to_s =~ /#{fspec['field does not have']}/i }
        end
        tmpfields.each { |f| acc << f }
      end

      acc
    end
  end
end
