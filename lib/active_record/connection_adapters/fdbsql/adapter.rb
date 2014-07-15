#
# FoundationDB SQL Layer ActiveRecord Adapter
# Copyright (c) 2013-2014 FoundationDB, LLC
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

require 'active_record'
require 'active_record/base'
require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/statement_pool'
require 'arel/visitors/bind_visitor'

require 'active_record/connection_adapters/fdbsql/ar_ver'
require 'active_record/connection_adapters/fdbsql/column'
require 'active_record/connection_adapters/fdbsql/database_limits'
require 'active_record/connection_adapters/fdbsql/database_statements'
require 'active_record/connection_adapters/fdbsql/helpers'
require 'active_record/connection_adapters/fdbsql/quoting'
require 'active_record/connection_adapters/fdbsql/schema_statements'
require 'active_record/connection_adapters/fdbsql/statement_pool'
require 'active_record/connection_adapters/fdbsql/table'
require 'active_record/connection_adapters/fdbsql/table_definition'
require 'active_record/connection_adapters/fdbsql/typeid'

if ActiveRecord::ConnectionAdapters::FdbSqlAdapter::ArVer::GTEQ_4
  require 'active_record/connection_adapters/fdbsql/schema_creation'
  require 'active_record/connection_adapters/fdbsql/types'
end


# FoundationDB SQL Layer currently uses the Postgres protocol
require 'pg'

module ActiveRecord

  class Base

    def self.fdbsql_connection(config)
      config = config.symbolize_keys
      config[:host]     = 'localhost' unless config[:host]
      config[:port]     = 15432       unless config[:port]
      config[:username] = 'fdbsql'    unless config[:username]
      config[:password] = ''          unless config[:password]
      config[:encoding] = 'UTF8'      unless config[:encoding]

      if config.key?(:database)
        database = config[:database]
      else
        raise ArgumentError, "No database specified. Missing config option: database"
      end

      # pg doesn't allow unconnected connections so just forward parameters
      conn_hash = {
        :host => config[:host],
        :port => config[:port],
        :dbname => config[:database],
        :user => config[:username],
        :password => config[:password]
      }
      ConnectionAdapters::FdbSqlAdapter.new(nil, logger, conn_hash, config)
    end

  end


  module ConnectionAdapters

    class FdbSqlAdapter < AbstractAdapter

      class Arel::Visitors::FdbSql < Arel::Visitors::ToSql
        private
          # NB: Second argument added in 4.0.1
          def visit_Arel_Nodes_Lock(o, a = nil)
            # SQL Layer does not support row locks
          end
      end


      class BindSubstitution < Arel::Visitors::FdbSql
        include Arel::Visitors::BindVisitor
      end


      include DatabaseLimits
      include DatabaseStatements
      include Quoting
      include SchemaStatements
      include TypeID

      if ArVer::GTEQ_4
        include Types
      end


      def initialize(connection, logger, connection_hash, config)
        super(connection, logger)
        @prepared_statements = config.fetch(:prepared_statements) { true }
        if @prepared_statements
          @visitor = Arel::Visitors::FdbSql.new self
        else
          @visitor = BindSubstitution.new self
        end
        @connection_hash = connection_hash
        @config = config
        connect
        @statements = FdbSqlStatementPool.new(@connection, config.fetch(:statement_limit) { 1000 })
      end


      # ADAPTER ==================================================

      if ArVer::GTEQ_4
        def schema_creation
          FdbSqlSchemaCreation.new self
        end
      end

      def adapter_name
        ADAPTER_NAME
      end

      def supports_migrations?
        true
      end

      def supports_primary_key?
        true
      end

      def supports_count_distinct?
        true
      end

      def supports_ddl_transactions?
        false
      end

      def supports_bulk_alter?
        false
      end

      def supports_savepoints?
        false
      end

      def prefetch_primary_key?(table_name = nil)
        false
      end

      def supports_index_sort_order?
        # As of 1.9.2, DESC is parsed but rejected
        false
      end

      def supports_explain?
        true
      end

      def supports_insert_with_returning?
        true
      end


      # REFERENTIAL INTEGRITY ====================================

      def disable_referential_integrity
        # Not yet supported
        yield
      end


      # CONNECTION MANAGEMENT ====================================

      def active?
        @connection.query 'SELECT 1'
        true
      rescue PGError
        false
      end

      if ArVer::GTEQ_4_0_4
        def active_threadsafe?
          @connection.connect_poll != PG::PGRES_POLLING_FAILED
        end
      end

      def reconnect!
        super
        clear_cache!
        @connection.reset
        @open_transactions = 0
        configure_connection
      end

      def disconnect!
        super
        clear_cache!
        @connection.close
      rescue
        nil
      end

      def reset!
        super
        clear_cache!
      end

      def clear_cache!
        @statements.clear
      end


      protected

        # Shouldn't escape to user, caught and handled in exec_cache()
        class StalePreparedStatement < ActiveRecord::StatementInvalid
        end


        def translate_exception(exception, message)
          case exception.result.try(:error_field, PGresult::PG_DIAG_SQLSTATE)
          when DUPLICATE_KEY_CODE
            RecordNotUnique.new(message, exception)
          when FK_REFERENCING_VIOLATION_CODE, FK_REFERENCED_VIOLATION_CODE
            InvalidForeignKey.new(message, exception)
          when STALE_STATEMENT_CODE
            StalePreparedStatement.new(message)
          else
            super
          end
        rescue
          super
        end

        # Added in 4.1. Redefine for use prior.
        def without_prepared_statement?(binds)
          !@prepared_statements || binds.empty?
        end


        # FdbSql ===================================================

        def stmt_cache_prefix
          @config[:database]
        end

        def sql_layer_version
          @sql_layer_version
        end

        def encoding
          @config[:encoding]
        end


      private

        ADAPTER_NAME = 'FDBSQL'.freeze
        DUPLICATE_KEY_CODE = '23501'
        FK_REFERENCING_VIOLATION_CODE = '23503'
        FK_REFERENCED_VIOLATION_CODE = '23504'
        STALE_STATEMENT_CODE = '0A50A'


        def connect
          @connection = PG::Connection.new(@connection_hash)
          configure_connection
        end

        def configure_connection
          @connection.set_client_encoding(@config[:encoding])

          # Swallow warnings
          @connection.set_notice_receiver { |proc| }

          ver = select_one('SELECT VERSION()', ADAPTER_NAME).map { |r|
            m = r[1].match('^.* (\d+)\.(\d+)\.(\d+)')
            if m.nil?
              raise "No match when checking FDB SQL Layer version: #{r[1]}"
            end
            m
          }[0]

          # Combine into single number, two digits per part: 1.9.3 => 10903
          @sql_layer_version = (100 * ver[1].to_i + ver[2].to_i) * 100 + ver[3].to_i
          if @sql_layer_version < 10902
            raise "Unsupported FDB SQL Layer version: #{@sql_layer_version} (#{ver[0]})"
          end
          if @sql_layer_version == 10902
            warn "Connected to FDB SQL Layer with significant known limitations: #{ver[0]}"
          end

          # TODO: Timezone when supported by SQL Layer
          #if ActiveRecord::Base.default_timezone == :utc
          #  # Set conn to UTC
          #elsif @local_tz
          #  # SET conn to @local_tz
          #end
        end

    end

  end

end

