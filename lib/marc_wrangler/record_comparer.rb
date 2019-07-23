module MarcWrangler
  class RecordComparer
    def initialize(ri, ex_ri, spec)
      @ri = ri
      @ex_ri = ex_ri
      @spec = spec
      @ri_fields = ri.marc.fields
      @ex_ri_fields = ex_ri.marc.fields

      flag_omitted_fields
      return unless changed? || @spec['incoming record output files']['STATIC'] != 'do not output'

      flag_ac_fields if spec['flag AC recs with changed headings']
    end

    def flag_omitted_fields
      omitted_fields_spec = @spec['omit from comparison fields']
      self.class.flag_omitted_fields(@ri_fields, omitted_fields_spec)
      self.class.flag_omitted_fields(@ex_ri_fields, omitted_fields_spec)
    end

    def self.get_fields_by_spec(fields, spec)
      acc = []
      spec.each do |fspec|
        tmpfields = fields.select { |f| f.tag =~ /#{fspec['tag']}/ }
        if fspec.has_key?('i1')
          tmpfields.select! { |f| f.indicator1 =~ /#{fspec['i1']}/ }
        end
        if fspec.has_key?('i2')
          tmpfields.select! { |f| f.indicator2 =~ /#{fspec['i2']}/ }
        end
        if fspec.has_key?('field has')
          tmpfields.select! { |f| f.to_s =~ /#{fspec['field has']}/i }
        end
        if fspec.has_key?('field does not have')
          tmpfields.reject! { |f| f.to_s =~ /#{fspec['field does not have']}/i }
        end
        tmpfields.each { |f| acc << f }
      end

      acc
    end

    def self.flag_omitted_fields(fields, spec)
      self.get_fields_by_spec(fields, spec).each { |f| f.omitted = true }
    end

    def flag_ac_fields
      ac_fields_spec = @spec['fields under AC']
      self.class.flag_ac_fields(@ri_fields, ac_fields_spec)
      self.class.flag_ac_fields(@ex_ri_fields, ac_fields_spec)
    end

    def self.flag_ac_fields(fields, spec)
      self.get_fields_by_spec(fields, spec).each { |f| f.ac = true }
    end

    def static?
      !changed?
    end

    def changed?
      @changed ||= detect_change
    end

    def detect_change
      return true unless comparable_in_fields.length == comparable_ex_fields.length
      @comparable_in_fields.each_with_index do |f, i|
        return true unless f.norm_string == @comparable_ex_fields[i].norm_string
      end
      nil
    end

    def ac_change?
      @ac_change ||= detect_ac_change
    end

    def detect_ac_change
      return true unless ac_in_fields.length == ac_ex_fields.length
      @ac_in_fields.each_with_index do |f, i|
        return true unless f.norm_string == @ac_ex_fields[i].norm_string
      end
      nil
    end

    def comparable_in_fields
      @comparable_in_fields ||=
        @ri_fields.reject { |f| f.omitted }.
        sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end

    def comparable_ex_fields
      @comparable_ex_fields ||=
        @ex_ri_fields.reject { |f| f.omitted }.
        sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end

    def ac_in_fields
      @ac_in_fields ||=
        @ri_fields.select { |f| f.ac }.
        sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end

    def ac_ex_fields
      @ac_ex_fields ||= @ex_ri_fields.
        select { |f| f.ac }.
        sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end
  end
end
