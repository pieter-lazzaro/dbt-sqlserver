{% macro sqlserver__information_schema_name(database) -%}
  INFORMATION_SCHEMA
{%- endmacro %}


{% macro sqlserver__get_columns_in_query(select_sql) %}
    {% call statement('get_columns_in_query', fetch_result=True, auto_begin=False) -%}
        select TOP 0 * from (
            {{ select_sql }}
        ) as __dbt_sbq
        where 0 = 1
    {% endcall %}

    {{ return(load_result('get_columns_in_query').table.columns | map(attribute='name') | list) }}
{% endmacro %}


{% macro sqlserver__list_relations_without_caching(schema_relation) %}
  {% call statement('list_relations_without_caching', fetch_result=True) -%}
    select
      TABLE_CATALOG as [database],
      TABLE_NAME as [name],
      TABLE_SCHEMA as [schema],
      case when TABLE_TYPE = 'BASE TABLE' then 'table'
           when TABLE_TYPE = 'VIEW' then 'view'
           else TABLE_TYPE
      end as table_type

    from [{{ schema_relation.database }}].INFORMATION_SCHEMA.TABLES
    where TABLE_SCHEMA like '{{ schema_relation.schema }}'
  {% endcall %}
  {{ return(load_result('list_relations_without_caching').table) }}
{% endmacro %}

{% macro sqlserver__list_schemas(database) %}
  {% call statement('list_schemas', fetch_result=True, auto_begin=False) -%}
    USE {{ database }};
    select  name as [schema]
    from sys.schemas
  {% endcall %}
  {{ return(load_result('list_schemas').table) }}
{% endmacro %}

{% macro sqlserver__create_schema(relation) -%}
  {% call statement('create_schema') -%}
    USE [{{ relation.database }}];
    IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = '{{ relation.without_identifier().schema }}')
    BEGIN
    EXEC('CREATE SCHEMA {{ relation.without_identifier().schema }}')
    END
  {% endcall %}
{% endmacro %}

{% macro sqlserver__drop_schema(relation) -%}
  {%- set tables_in_schema_query %}
      SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
      WHERE TABLE_SCHEMA = '{{ relation.schema }}'
  {% endset %}
  {% set tables_to_drop = run_query(tables_in_schema_query).columns[0].values() %}
  {% for table in tables_to_drop %}
    {%- set schema_relation = adapter.get_relation(database=relation.database,
                                               schema=relation.schema,
                                               identifier=table) -%}
    {% do drop_relation(schema_relation) %}
  {%- endfor %}

  {% call statement('drop_schema') -%}
      IF EXISTS (SELECT * FROM sys.schemas WHERE name = '{{ relation.schema }}')
      BEGIN
      EXEC('DROP SCHEMA {{ relation.schema }}')
      END  {% endcall %}
{% endmacro %}

{% macro sqlserver__drop_relation(relation) -%}
  {% call statement('drop_relation', auto_begin=False) -%}
    {{ sqlserver__drop_relation_script(relation) }}
  {%- endcall %}
{% endmacro %}

{% macro sqlserver__drop_relation_script(relation) -%}
  {% if relation.type == 'view' -%}
   {% set object_id_type = 'V' %}
   {% elif relation.type == 'table'%}
   {% set object_id_type = 'U' %}
   {%- else -%} invalid target name
   {% endif %}
  USE [{{ relation.database }}];
  if object_id ('{{ relation.include(database=False) }}','{{ object_id_type }}') is not null
      begin
      drop {{ relation.type }} {{ relation.include(database=False) }}
      end
{% endmacro %}

{% macro sqlserver__check_schema_exists(information_schema, schema) -%}
  {% call statement('check_schema_exists', fetch_result=True, auto_begin=False) -%}
    --USE {{ database_name }}
    SELECT count(*) as schema_exist FROM sys.schemas WHERE name = '{{ schema }}'
  {%- endcall %}
  {{ return(load_result('check_schema_exists').table) }}
{% endmacro %}


{% macro sqlserver__create_view_exec(relation, sql) -%}
    {%- set temp_view_sql = sql.replace("'", "''") -%}
    execute('create view {{ relation.include(database=False) }} as
    {{ temp_view_sql }}
    ');
{% endmacro %}


{% macro sqlserver__create_view_as(relation, sql) -%}
    USE [{{ relation.database }}];
    {{ sqlserver__create_view_exec(relation, sql) }}
{% endmacro %}


{% macro sqlserver__rename_relation(from_relation, to_relation) -%}
  {% call statement('rename_relation') -%}
    USE [{{ to_relation.database }}];
    EXEC sp_rename '{{ from_relation.schema }}.{{ from_relation.identifier }}', '{{ to_relation.identifier }}'
    IF EXISTS(
    SELECT *
    FROM sys.indexes
    WHERE name='{{ from_relation.schema }}_{{ from_relation.identifier }}_cci' and object_id = OBJECT_ID('{{ from_relation.schema }}.{{ to_relation.identifier }}'))
    EXEC sp_rename N'{{ from_relation.schema }}.{{ to_relation.identifier }}.{{ from_relation.schema }}_{{ from_relation.identifier }}_cci', N'{{ from_relation.schema }}_{{ to_relation.identifier }}_cci', N'INDEX'
  {%- endcall %}
{% endmacro %}

{% macro sqlserver__create_clustered_columnstore_index(relation) -%}
  {%- set cci_name = relation.schema ~ '_' ~ relation.identifier ~ '_cci' -%}
  {%- set relation_name = relation.schema ~ '_' ~ relation.identifier -%}
  {%- set full_relation = relation.schema ~ '.' ~ relation.identifier -%}
  use [{{ relation.database }}];
  if EXISTS (
        SELECT * FROM
        sys.indexes WHERE name = '{{cci_name}}'
        AND object_id=object_id('{{relation_name}}')
    )
  DROP index {{full_relation}}.{{cci_name}}
  CREATE CLUSTERED COLUMNSTORE INDEX {{cci_name}}
    ON {{full_relation}}
{% endmacro %}

{% macro sqlserver__create_table_as(temporary, relation, sql) -%}
   {%- set as_columnstore = config.get('as_columnstore', default=true) -%}
   {% set tmp_relation = relation.incorporate(
   path={"identifier": relation.identifier.replace("#", "") ~ '_temp_view'},
   type='view')-%}
   {%- set temp_view_sql = sql.replace("'", "''") -%}

   {{ sqlserver__drop_relation_script(tmp_relation) }}

   {{ sqlserver__drop_relation_script(relation) }}

   USE [{{ relation.database }}];
   EXEC('create view {{ tmp_relation.include(database=False) }} as
    {{ temp_view_sql }}
    ');

   SELECT * INTO {{ relation }} FROM
    {{ tmp_relation }}

   {{ sqlserver__drop_relation_script(tmp_relation) }}
    
   {% if not temporary and as_columnstore -%}
   {{ sqlserver__create_clustered_columnstore_index(relation) }}
   {% endif %}

{% endmacro %}_

{% macro sqlserver__insert_into_from(to_relation, from_relation) -%}
  SELECT * INTO {{ to_relation }} FROM {{ from_relation }}
{% endmacro %}

{% macro sqlserver__current_timestamp() -%}
  SYSDATETIME()
{%- endmacro %}

{% macro sqlserver__get_columns_in_relation(relation) -%}
  {% call statement('get_columns_in_relation', fetch_result=True) %}
      SELECT
          COLUMN_NAME,
          DATA_TYPE,
          CHARACTER_MAXIMUM_LENGTH,
          NUMERIC_PRECISION,
          NUMERIC_SCALE
      FROM
          (select
              ORDINAL_POSITION,
              COLUMN_NAME,
              DATA_TYPE,
              CHARACTER_MAXIMUM_LENGTH,
              NUMERIC_PRECISION,
              NUMERIC_SCALE
          from [{{ relation.database }}].INFORMATION_SCHEMA.COLUMNS
          where TABLE_NAME = '{{ relation.identifier }}'
            and TABLE_SCHEMA = '{{ relation.schema }}'
          UNION ALL
          select
              ORDINAL_POSITION,
              COLUMN_NAME collate database_default,
              DATA_TYPE collate database_default,
              CHARACTER_MAXIMUM_LENGTH,
              NUMERIC_PRECISION,
              NUMERIC_SCALE
          from tempdb.INFORMATION_SCHEMA.COLUMNS
          where TABLE_NAME like '{{ relation.identifier }}%') cols
      order by ORDINAL_POSITION


  {% endcall %}
  {% set table = load_result('get_columns_in_relation').table %}
  {{ return(sql_convert_columns_in_relation(table)) }}
{% endmacro %}

{% macro sqlserver__make_temp_relation(base_relation, suffix) %}
    {% set tmp_identifier = '#' ~  base_relation.identifier ~ suffix %}
    {% set tmp_relation = base_relation.incorporate(
                                path={"identifier": tmp_identifier}) -%}

    {% do return(tmp_relation) %}
{% endmacro %}

{% macro sqlserver__snapshot_string_as_time(timestamp) -%}
    {%- set result = "CONVERT(DATETIME2, '" ~ timestamp ~ "')" -%}
    {{ return(result) }}
{%- endmacro %}
