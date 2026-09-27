-- Recovered production helper for isolated Valentina V9 certification.
CREATE OR REPLACE FUNCTION public.atlas_next_document_display_id(p_empresa_id uuid, p_document_type text DEFAULT 'QUOTE'::text, p_prefix text DEFAULT 'COT'::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_year integer;
  v_number bigint;
  v_prefix text;
  v_display_id text;
begin

  v_year :=
    extract(
      year from now()
    )::integer;


  v_prefix :=
    upper(
      coalesce(
        nullif(
          trim(p_prefix),
          ''
        ),
        'COT'
      )
    );


  insert into public.atlas_document_sequences (
    empresa_id,
    document_type,
    document_year,
    last_number,
    prefix
  )
  values (
    p_empresa_id,
    upper(p_document_type),
    v_year,
    1,
    v_prefix
  )

  on conflict (
    empresa_id,
    document_type,
    document_year
  )

  do update set

    last_number =
      public.atlas_document_sequences.last_number
      + 1,

    updated_at =
      now()

  returning
    last_number,
    prefix

  into
    v_number,
    v_prefix;


  v_display_id :=
    concat(
      v_prefix,
      '-',
      v_year,
      '-',
      lpad(
        v_number::text,
        6,
        '0'
      )
    );


  return v_display_id;

end;
$function$;
