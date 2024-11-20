-- Type Generator: Generate types for any programming language directly from Postgres.


-- Currently supported programming languages:
CREATE TYPE programming_language AS ENUM ('python', 'go', 'swift','dart', 'typescript');
--drop type programming_language cascade;


CREATE TYPE lang_primitive_types AS (
    int_type       text,
    float_type     text,
    bool_type      text,
    json_type      text,
    array_type     text,
    binary_type    text,
    string_type    text,
    void_type      text,
    time_type      text,
    timestamp_type text,
    default_type   text,
    comment_start  text,
    type_template  text
);
--drop type lang_primitive_types cascade;


-- Function to get foreign key relationships for a given table.
create or replace function get_fk(table_name text, column_name text)
returns table(
   constraint_name     text,
   schema_name         text,
   table_name          text,
   column_name         text,
   foreign_schema_name text,
   foreign_table_name  text,
   foreign_column_name text
) as $$
   -- Join ref constraints with key column usage to get FK relationships.
   select c.constraint_name
   , x.table_schema as schema_name
   , x.table_name
   , x.column_name
   , y.table_schema as foreign_schema_name
   , y.table_name as foreign_table_name
   , y.column_name as foreign_column_name
   from information_schema.referential_constraints c
   join information_schema.key_column_usage x
       on x.constraint_name = c.constraint_name
   join information_schema.key_column_usage y
       on y.ordinal_position = x.position_in_unique_constraint
       and y.constraint_name = c.unique_constraint_name
   where x.table_schema = 'public' and x.table_name = $1 and x.column_name = $2
   order by c.constraint_name, x.ordinal_position;
$$ language SQL;


-- Function to generate types for a given programming language argument.
create or replace function generate_types (table_ text, language programming_language)
returns text as $$
DECLARE
   language_tuple_info lang_primitive_types := types_tuple_definition(language);
   dataclass     text;
   property      record;
   TAB           varchar := '    ';
   class_name    text;
   fk_type       text := 'Id';
   comments      text := language_tuple_info.comment_start;
   default_comments      text := language_tuple_info.comment_start;
   default_value text;
   fk_property   record;
BEGIN
   -- Type string template
   dataclass := language_tuple_info.type_template;

       -- Loop through all columns in the table
       for property in
       SELECT column_name, type_mapper(lower(data_type), language) as type_mapper, table_name, column_default
       FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = $1
       loop
           class_name := property.table_name;

           -- Handle default values
           if property.column_default is null
           then
              default_value := '';
           else
              default_comments := replace(comments, 'comment', ' default value: ' || property.column_default );
              default_value := default_comments;
           end if;
         
           for fk_property in 
           select fk.* from get_fk(class_name, property.column_name) as fk
           loop
              -- Add FK comments
              comments := replace(comments, 'comment',
              initcap(fk_property.table_name) || '.' || fk_property.constraint_name ||
              ' references '|| initcap(fk_property.foreign_table_name) ||'.'||
              fk_property.foreign_column_name);

               dataclass := replace(dataclass, '#field',
               comments|| E'\n' || TAB || '#field');

              comments := language_tuple_info.comment_start;
           end loop;

           -- Add field to type
           dataclass := replace(dataclass, '#field',
               property.column_name || ': ' || property.type_mapper ||
               default_value || E'\n\n' || TAB || '#field');
           default_comments := language_tuple_info.comment_start;
       end loop;

       -- Clean up template placeholders
       dataclass := replace(dataclass, '#field', '');
       dataclass := replace(dataclass, '#class_name', initcap(class_name));

       RETURN dataclass;
END;
$$ language plpgsql;


-- Function that takes a programming language argument and returns its concrete types.
create or replace function types_tuple_definition(language programming_language) returns lang_primitive_types as
$$
begin
   case
     when language = 'python' then 
     return row('int', 'float', 'bool', 'Dict[str, Any]', 'List[Any]', 'bytes',
    'str', '', 'datetime.datetime', 'datetime.timestamp', 'str', '#comment',
    '@dataclass
class #class_name:
    #field')::lang_primitive_types;

     when language = 'go' then 
     return row(
    'int', 'float64', 'bool', 'map[string]interface{}', '[]interface{}', '[]byte',
    'string', '*int', 'time.Time', 'time.Time', 'string', '//comment',
    'type #class_name struct {
    #field
    }')::lang_primitive_types;

     when language = 'swift' then 
     return row(
    'Int', 'Double', 'Bool', '[String: Any]', '[Any]', 'Data',
    'String', 'Int?', 'Date', 'Date', 'String', '//comment',
    'struct #class_name {
    #field
    }')::lang_primitive_types;

    when language = 'dart' then
    return row(
    'int', 'double', 'bool', 'String', 'List<dynamic>', 'Uint8List',
    'String', 'void', 'DateTime', 'DateTime', 'String', '//comment',
    'class #class_name {
    #field
    }')::lang_primitive_types;

    when language = 'typescript' then
    return row(
    'number', 'number', 'boolean', 'Json', 'Any[]', 'Uint8Array',
    'string', 'void', 'Date', 'Date', 'Any', '//comment',
    'type #class_name = {
    #field
    }')::lang_primitive_types;

   end case;
end;
$$ language plpgsql;


-- Function to generate types for a programming language argument.
create or replace function generate_schema_types(schema text, language programming_language)
returns text as $$
declare 
  model text := '';
  row record;
begin
     -- Get types for each table in the schema
     for row in 
     select generate_types(table_name, language) generated_model
     from information_schema.tables
     where table_schema = $1
     loop
        model := model || row.generated_model || E'\n\n';
     end loop;
     if language = 'typescript'
     then
      model := 'export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]'|| E'\n' || model;
     end if;
     return model;
end;
$$ language plpgsql;


-- Function to map types for a programming language argument.
create or replace function type_mapper (type text, language programming_language)
returns text as $$
-- Create base types for any programming language

DECLARE selected_type lang_primitive_types := types_tuple_definition(language);

begin
   -- Case to map Postgres types to language types.
   case
     -- Integer
     when ($1 like '%int%') then return selected_type.int_type;
     -- Float
     when ($1 like 'float%') or ($1 = 'numeric') then return selected_type.float_type;
     -- JSON
     when $1 in ('jsonb', 'json')  then return selected_type.json_type;
     -- Array
     when $1 in ('vector', 'array') then return selected_type.array_type;
     -- Binary
     when $1 = 'bytea' then return selected_type.binary_type;
     -- String
     when ($1 like '%char%') or ($1 like '%text%') or ($1 = 'uuid' )then return selected_type.string_type;
     -- Boolean
     when ($1 = 'bool') then return selected_type.bool_type;
     -- Void
     when ($1 = 'void') then return selected_type.void_type;
     -- Time
     when ($1 in ('time', 'timez')) then return selected_type.time_type;
     -- Timestamp
     when ($1 like '%timestamp%') then return selected_type.timestamp_type;
     -- Default, return str with original type as comment
     else return 'str # ' || $1;
   end case;
   return 'not implemented';
end;
$$ language plpgsql;













-- Uncomment and test:

-- select generate_schema_types ('public', 'python');

-- select generate_schema_types ('public', 'go');

-- select generate_schema_types ('public', 'swift');

-- select generate_schema_types ('public', 'dart');

-- select generate_schema_types ('public', 'typescript');
