module MarcWrangler
  class RecordComparer
    def initialize(rec, ex_rec, spec)
      @spec = spec
      @ri_fields = rec.fields
      @ex_ri_fields = ex_rec.fields

      @changed = detect_change(comparable_in_fields, comparable_ex_fields)

      @output_static = @spec['incoming record output files'] &&
                       @spec['incoming record output files']['STATIC'] != 'do not output'
    end

    def static?
      !changed?
    end

    def changed?
      @changed
    end

    def detect_change(in_fields, ex_fields)
      return true unless in_fields.length == ex_fields.length
      in_fields.each_with_index do |f, i|
        return true unless f.norm_string == ex_fields[i].norm_string
      end
      false
    end

    def ac_change?
      return @ac_change if @ac_change

      return unless @changed || @output_static

      @ac_change ||= detect_ac_change(ac_in_fields, ac_ex_fields)
    end

    def detect_ac_change(in_fields, ex_fields)
      return true unless in_fields.length == ex_fields.length
      in_fields.each_with_index do |f, i|
        return true unless f.norm_string == ex_fields[i].norm_string
      end

      false
    end

    def comparable_in_fields
      fields = @ri_fields - Config.get_fields_by_spec(@ri_fields, @spec['omit from comparison fields'])
      fields.sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end

    def comparable_ex_fields
      fields = @ex_ri_fields - Config.get_fields_by_spec(@ex_ri_fields, @spec['omit from comparison fields'])
      fields.sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end

    def ac_in_fields
      fields = Config.get_fields_by_spec(@ri_fields, @spec['fields under AC'])
      fields.sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end

    def ac_ex_fields
      fields = Config.get_fields_by_spec(@ex_ri_fields, @spec['fields under AC'])
      fields.sort_by { |f| f.norm_string }.
        uniq { |f| f.norm_string }
    end
  end
end
