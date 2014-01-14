module ActiveRecord

  module ConnectionAdapters
    
    class FdbSqlAdapter < AbstractAdapter
      
      class FdbSqlSchemaCreation < SchemaCreation
        private

          def visit_AddColumn(o)
            sql_type = type_to_sql(o.type.to_sym, o.limit, o.precision, o.scale)
            sql = "ADD COLUMN #{quote_column_name(o.name)} #{sql_type}"
            add_column_options!(sql, column_options(o))
          end
      end

    end

  end

end

