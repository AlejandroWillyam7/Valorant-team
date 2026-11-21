-- VALORANT TEAM MANAGER 4.1
-- Execute este script inteiro no Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.vtm_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  team_a text not null,
  team_b text not null,
  token_a text not null,
  token_b text not null,
  first_team text check (first_team in ('A','B')),
  history jsonb not null default '[]'::jsonb,
  sides jsonb not null default '{}'::jsonb,
  archive jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Garante as colunas esperadas mesmo se a tabela vtm_rooms já existia da versão anterior.
alter table public.vtm_rooms add column if not exists code text;
alter table public.vtm_rooms add column if not exists team_a text;
alter table public.vtm_rooms add column if not exists team_b text;
alter table public.vtm_rooms add column if not exists token_a text;
alter table public.vtm_rooms add column if not exists token_b text;
alter table public.vtm_rooms add column if not exists first_team text;
alter table public.vtm_rooms add column if not exists history jsonb not null default '[]'::jsonb;
alter table public.vtm_rooms add column if not exists sides jsonb not null default '{}'::jsonb;
alter table public.vtm_rooms add column if not exists archive jsonb not null default '[]'::jsonb;
alter table public.vtm_rooms add column if not exists created_at timestamptz not null default now();
alter table public.vtm_rooms add column if not exists updated_at timestamptz not null default now();
create unique index if not exists vtm_rooms_code_uidx on public.vtm_rooms(code);

alter table public.vtm_rooms enable row level security;
revoke all on public.vtm_rooms from anon, authenticated;

create or replace function public.vtm_create_room(p_code text,p_team_a text,p_team_b text,p_token_a text,p_token_b text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if length(coalesce(p_code,'')) < 5 or length(coalesce(p_token_a,'')) < 20 or length(coalesce(p_token_b,'')) < 20 then
    raise exception 'Dados da sala inválidos.';
  end if;
  insert into public.vtm_rooms(code,team_a,team_b,token_a,token_b)
  values(upper(p_code),left(trim(p_team_a),60),left(trim(p_team_b),60),p_token_a,p_token_b);
  return jsonb_build_object('created',true,'code',upper(p_code));
end; $$;

create or replace function public.vtm_get_room(p_code text,p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.vtm_rooms%rowtype; who text;
begin
  select * into r from public.vtm_rooms where code=upper(p_code);
  if not found then raise exception 'Sala não encontrada.'; end if;
  if p_token=r.token_a then who:='A'; elsif p_token=r.token_b then who:='B'; else raise exception 'Convite inválido.'; end if;
  return jsonb_build_object('code',r.code,'team_a',r.team_a,'team_b',r.team_b,'first_team',r.first_team,'history',r.history,'sides',r.sides,'archive',r.archive,'created_at',r.created_at,'your_team',who,'decider_side_team','A');
end; $$;

create or replace function public.vtm_set_first(p_code text,p_token text,p_first text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.vtm_rooms%rowtype;
begin
  select * into r from public.vtm_rooms where code=upper(p_code) for update;
  if not found then raise exception 'Sala não encontrada.'; end if;
  if p_token<>r.token_a then raise exception 'Somente o capitão A pode iniciar o sorteio.'; end if;
  if p_first not in ('A','B') then raise exception 'Resultado do sorteio inválido.'; end if;
  if r.first_team is not null then raise exception 'O sorteio já foi realizado.'; end if;
  update public.vtm_rooms set first_team=p_first,updated_at=now() where id=r.id;
  return jsonb_build_object('first_team',p_first);
end; $$;

create or replace function public.vtm_room_action(p_code text,p_token text,p_kind text,p_map text,p_side text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.vtm_rooms%rowtype; who text; plan jsonb; current_step jsonb; used_count int; remaining_count int; pick_team text; map_exists boolean;
begin
  select * into r from public.vtm_rooms where code=upper(p_code) for update;
  if not found then raise exception 'Sala não encontrada.'; end if;
  if p_token=r.token_a then who:='A'; elsif p_token=r.token_b then who:='B'; else raise exception 'Convite inválido.'; end if;
  if p_kind='SIDE' then
    if p_side not in ('Ataque','Defesa') then raise exception 'Lado inválido.'; end if;
    if p_map is null or trim(p_map)='' then raise exception 'Mapa inválido.'; end if;
    if not exists(select 1 from jsonb_array_elements(r.history) x where x->>'kind'='PICK' and x->>'map'=p_map) and jsonb_array_length(r.history)<6 then raise exception 'Esse mapa ainda não foi definido.'; end if;
    if r.sides ? p_map then raise exception 'O lado inicial já foi escolhido.'; end if;
    if jsonb_array_length(r.history)=6 and not exists(select 1 from jsonb_array_elements(r.history) x where x->>'map'=p_map) then
      if who<>'A' then raise exception 'Somente a Equipe A escolhe o lado do decider nesta versão.'; end if;
    else
      select case when x->>'team'='A' then 'B' else 'A' end into pick_team from jsonb_array_elements(r.history) x where x->>'kind'='PICK' and x->>'map'=p_map limit 1;
      if pick_team is distinct from who then raise exception 'A escolha do lado pertence ao capitão adversário ao que fez o pick.'; end if;
    end if;
    update public.vtm_rooms set sides=sides||jsonb_build_object(p_map,p_side),updated_at=now() where id=r.id;
    return jsonb_build_object('saved',true);
  end if;
  if p_kind not in ('BAN','PICK') then raise exception 'Ação inválida.'; end if;
  if r.first_team is null then raise exception 'O sorteio precisa acontecer antes do veto.'; end if;
  used_count:=jsonb_array_length(r.history);
  if used_count>=6 then raise exception 'O veto já foi concluído.'; end if;
  if r.first_team='A' then
    plan:=jsonb_build_array(jsonb_build_object('kind','BAN','team','A'),jsonb_build_object('kind','BAN','team','B'),jsonb_build_object('kind','PICK','team','A'),jsonb_build_object('kind','PICK','team','B'),jsonb_build_object('kind','BAN','team','A'),jsonb_build_object('kind','BAN','team','B'));
  else
    plan:=jsonb_build_array(jsonb_build_object('kind','BAN','team','B'),jsonb_build_object('kind','BAN','team','A'),jsonb_build_object('kind','PICK','team','B'),jsonb_build_object('kind','PICK','team','A'),jsonb_build_object('kind','BAN','team','B'),jsonb_build_object('kind','BAN','team','A'));
  end if;
  current_step:=plan->used_count;
  if current_step->>'team'<>who then raise exception 'Ainda não é a vez da sua equipe.'; end if;
  if current_step->>'kind'<>p_kind then raise exception 'Tipo de ação fora da ordem.'; end if;
  if exists(select 1 from jsonb_array_elements(r.history) x where x->>'map'=p_map) then raise exception 'Esse mapa já foi escolhido.'; end if;
  if trim(coalesce(p_map,''))='' then raise exception 'Selecione um mapa.'; end if;
  update public.vtm_rooms set history=history||jsonb_build_array(jsonb_build_object('kind',p_kind,'team',who,'map',p_map,'created_at',now())),updated_at=now() where id=r.id;
  return jsonb_build_object('saved',true,'action',p_kind,'team',who,'map',p_map);
end; $$;

create or replace function public.vtm_undo(p_code text,p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.vtm_rooms%rowtype; who text; last_item jsonb; new_history jsonb;
begin
  select * into r from public.vtm_rooms where code=upper(p_code) for update;
  if not found then raise exception 'Sala não encontrada.'; end if;
  if p_token=r.token_a then who:='A'; elsif p_token=r.token_b then who:='B'; else raise exception 'Convite inválido.'; end if;
  if jsonb_array_length(r.history)=0 then raise exception 'Não há ação para desfazer.'; end if;
  last_item:=r.history->(jsonb_array_length(r.history)-1);
  if who<>'A' and who<>(last_item->>'team') then raise exception 'Somente o capitão responsável pela última ação ou o capitão A pode desfazer.'; end if;
  new_history:=r.history-(jsonb_array_length(r.history)-1);
  update public.vtm_rooms set history=new_history,updated_at=now() where id=r.id;
  return jsonb_build_object('undone',true);
end; $$;

revoke all on function public.vtm_create_room(text,text,text,text,text) from public;
revoke all on function public.vtm_get_room(text,text) from public;
revoke all on function public.vtm_set_first(text,text,text) from public;
revoke all on function public.vtm_room_action(text,text,text,text,text) from public;
revoke all on function public.vtm_undo(text,text) from public;
grant execute on function public.vtm_create_room(text,text,text,text,text) to anon, authenticated;
grant execute on function public.vtm_get_room(text,text) to anon, authenticated;
grant execute on function public.vtm_set_first(text,text,text) to anon, authenticated;
grant execute on function public.vtm_room_action(text,text,text,text,text) to anon, authenticated;
grant execute on function public.vtm_undo(text,text) to anon, authenticated;
