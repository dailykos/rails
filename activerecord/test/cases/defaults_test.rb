require "cases/helper"
require 'models/default'
require 'models/entrant'

class DefaultTest < ActiveRecord::TestCase
  def test_nil_defaults_for_not_null_columns
    column_defaults =
      if current_adapter?(:MysqlAdapter) && (Mysql.client_version < 50051 || (50100..50122).include?(Mysql.client_version))
        { 'id' => nil, 'name' => '',  'course_id' => nil }
      else
        { 'id' => nil, 'name' => nil, 'course_id' => nil }
      end

    column_defaults.each do |name, default|
      column = Entrant.columns_hash[name]
      assert !column.null, "#{name} column should be NOT NULL"
      assert_equal default, column.default, "#{name} column should be DEFAULT #{default.inspect}"
    end
  end

  if current_adapter?(:PostgreSQLAdapter, :OracleAdapter)
    def test_default_integers
      default = Default.new
      assert_instance_of Fixnum, default.positive_integer
      assert_equal 1, default.positive_integer
      assert_instance_of Fixnum, default.negative_integer
      assert_equal(-1, default.negative_integer)
      assert_instance_of BigDecimal, default.decimal_number
      assert_equal BigDecimal.new("2.78"), default.decimal_number
    end
  end

  if current_adapter?(:PostgreSQLAdapter)
    def test_multiline_default_text
      # older postgres versions represent the default with escapes ("\\012" for a newline)
      assert( "--- []\n\n" == Default.columns_hash['multiline_default'].default ||
               "--- []\\012\\012" == Default.columns_hash['multiline_default'].default)
    end

    def test_default_negative_integer
      assert_equal -1, Default.new.negative_integer
      assert_equal "-1", Default.new.negative_integer_before_type_cast
    end
  end
end

class DefaultStringsTest < ActiveRecord::TestCase
  class DefaultString < ActiveRecord::Base; end

  setup do
    @connection = ActiveRecord::Base.connection
    @connection.create_table :default_strings do |t|
      t.string :string_col, default: "Smith"
      t.string :string_col_with_quotes, default: "O'Connor"
    end
    DefaultString.reset_column_information
  end

  def test_default_strings
    assert_equal "Smith", DefaultString.new.string_col
  end

  def test_default_strings_containing_single_quotes
    assert_equal "O'Connor", DefaultString.new.string_col_with_quotes
  end

  teardown do
    @connection.drop_table :default_strings
  end
end

if current_adapter?(:MysqlAdapter, :Mysql2Adapter)
  class DefaultsTestWithoutTransactionalFixtures < ActiveRecord::TestCase
    # ActiveRecord::Base#create! (and #save and other related methods) will
    # open a new transaction. When in transactional fixtures mode, this will
    # cause Active Record to create a new savepoint. However, since MySQL doesn't
    # support DDL transactions, creating a table will result in any created
    # savepoints to be automatically released. This in turn causes the savepoint
    # release code in AbstractAdapter#transaction to fail.
    #
    # We don't want that to happen, so we disable transactional fixtures here.
    self.use_transactional_fixtures = false

    def using_strict(strict)
      connection = ActiveRecord::Base.remove_connection
      ActiveRecord::Base.establish_connection connection.merge(strict: strict)
      yield
    ensure
      ActiveRecord::Base.remove_connection
      ActiveRecord::Base.establish_connection connection
    end

    # MySQL cannot have defaults on text/blob columns. It reports the
    # default value as null.
    #
    # Despite this, in non-strict mode, MySQL will use an empty string
    # as the default value of the field, if no other value is
    # specified.
    #
    # Therefore, in non-strict mode, we want column.default to report
    # an empty string as its default, to be consistent with that.
    #
    # In strict mode, column.default should be nil.
    def test_mysql_text_not_null_defaults_non_strict
      using_strict(false) do
        with_text_blob_not_null_table do |klass|
          assert_equal '', klass.columns_hash['non_null_blob'].default
          assert_equal '', klass.columns_hash['non_null_text'].default

          assert_nil klass.columns_hash['null_blob'].default
          assert_nil klass.columns_hash['null_text'].default

          instance = klass.create!

          assert_equal '', instance.non_null_text
          assert_equal '', instance.non_null_blob

          assert_nil instance.null_text
          assert_nil instance.null_blob
        end
      end
    end

    def test_mysql_text_not_null_defaults_strict
      using_strict(true) do
        with_text_blob_not_null_table do |klass|
          assert_nil klass.columns_hash['non_null_blob'].default
          assert_nil klass.columns_hash['non_null_text'].default
          assert_nil klass.columns_hash['null_blob'].default
          assert_nil klass.columns_hash['null_text'].default

          assert_raises(ActiveRecord::StatementInvalid) { klass.create }
        end
      end
    end

    def with_text_blob_not_null_table
      klass = Class.new(ActiveRecord::Base)
      klass.table_name = 'test_mysql_text_not_null_defaults'
      klass.connection.create_table klass.table_name do |t|
        t.column :non_null_text, :text, :null => false
        t.column :non_null_blob, :blob, :null => false
        t.column :null_text, :text, :null => true
        t.column :null_blob, :blob, :null => true
      end

      yield klass
    ensure
      klass.connection.drop_table(klass.table_name) rescue nil
    end

    # MySQL uses an implicit default 0 rather than NULL unless in strict mode.
    # We use an implicit NULL so schema.rb is compatible with other databases.
    def test_mysql_integer_not_null_defaults
      klass = Class.new(ActiveRecord::Base)
      klass.table_name = 'test_integer_not_null_default_zero'
      klass.connection.create_table klass.table_name do |t|
        t.column :zero, :integer, :null => false, :default => 0
        t.column :omit, :integer, :null => false
      end

      assert_equal '0', klass.columns_hash['zero'].default
      assert !klass.columns_hash['zero'].null
      # 0 in MySQL 4, nil in 5.
      assert [0, nil].include?(klass.columns_hash['omit'].default)
      assert !klass.columns_hash['omit'].null

      assert_raise(ActiveRecord::StatementInvalid) { klass.create! }

      assert_nothing_raised do
        instance = klass.create!(:omit => 1)
        assert_equal 0, instance.zero
        assert_equal 1, instance.omit
      end
    ensure
      klass.connection.drop_table(klass.table_name) rescue nil
    end
  end
end

if current_adapter?(:PostgreSQLAdapter)
  class DefaultsUsingMultipleSchemasAndDomainTest < ActiveSupport::TestCase
    def setup
      @connection = ActiveRecord::Base.connection

      @old_search_path = @connection.schema_search_path
      @connection.schema_search_path = "schema_1, pg_catalog"
      @connection.create_table "defaults" do |t|
        t.text "text_col", :default => "some value"
        t.string "string_col", :default => "some value"
      end
      Default.reset_column_information
    end

    def test_text_defaults_in_new_schema_when_overriding_domain
      assert_equal "some value", Default.new.text_col, "Default of text column was not correctly parse"
    end

    def test_string_defaults_in_new_schema_when_overriding_domain
      assert_equal "some value", Default.new.string_col, "Default of string column was not correctly parse"
    end

    def test_bpchar_defaults_in_new_schema_when_overriding_domain
      @connection.execute "ALTER TABLE defaults ADD bpchar_col bpchar DEFAULT 'some value'"
      Default.reset_column_information
      assert_equal "some value", Default.new.bpchar_col, "Default of bpchar column was not correctly parse"
    end

    def test_text_defaults_after_updating_column_default
      @connection.execute "ALTER TABLE defaults ALTER COLUMN text_col SET DEFAULT 'some text'::schema_1.text"
      assert_equal "some text", Default.new.text_col, "Default of text column was not correctly parse after updating default using '::text' since postgreSQL will add parens to the default in db"
    end

    def test_default_containing_quote_and_colons
      @connection.execute "ALTER TABLE defaults ALTER COLUMN string_col SET DEFAULT 'foo''::bar'"
      assert_equal "foo'::bar", Default.new.string_col
    end

    teardown do
      @connection.schema_search_path = @old_search_path
      Default.reset_column_information
    end
  end
end
