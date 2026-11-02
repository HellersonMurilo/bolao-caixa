-- Bolão da Turma · banco de dados no Supabase
-- Cole tudo no SQL Editor do Supabase e clique em Run. Pode rodar de novo sem perder dados.
--
-- Regras de acesso:
--   * Só o organizador logado lê e altera bolões e jogos (cada conta vê apenas os próprios bolões).
--   * Quem tem o link do convite não faz login. Só consegue duas coisas, pelas funções abaixo:
--       get_convite(token)  -> dados do bolão para montar a tela (sem os jogos dos outros)
--       enviar_jogos(...)   -> adiciona jogos, validados aqui no banco, até o prazo do bolão
--   * Depois do prazo o link para de aceitar jogos. "Gerar link novo" invalida o link antigo.

create extension if not exists pgcrypto;

create table if not exists public.bolaos (
  id        uuid primary key default gen_random_uuid(),
  owner     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nome      text not null check (char_length(nome) between 1 and 80),
  lot       text not null check (lot in ('megasena','lotofacil','quina','lotomania','duplasena','diadesorte','timemania','maismilionaria')),
  conc      int  not null check (conc > 0),
  teim      int  not null default 1 check (teim between 1 and 12),
  prazo     timestamptz,
  preco     numeric(10,2) not null default 6,
  mx        int,
  div       text not null default 'todos' check (div in ('todos','cada')),
  pix       jsonb not null default '{}'::jsonb,
  adm       text,
  fone      text,
  token     uuid not null unique default gen_random_uuid(),
  criado    timestamptz not null default now()
);

create table if not exists public.jogos (
  id        uuid primary key default gen_random_uuid(),
  bolao_id  uuid not null references public.bolaos(id) on delete cascade,
  p         text not null check (char_length(p) between 1 and 60),
  d         int[] not null,
  t         int[],
  m         int check (m between 0 and 11),
  pago      boolean not null default false,
  reg       boolean not null default false,
  src       text not null default 'adm' check (src in ('adm','link')),
  criado    timestamptz not null default now()
);
create index if not exists jogos_bolao_idx on public.jogos(bolao_id);
create index if not exists bolaos_owner_idx on public.bolaos(owner);

alter table public.bolaos enable row level security;
alter table public.jogos  enable row level security;

drop policy if exists "dono gerencia bolaos" on public.bolaos;
create policy "dono gerencia bolaos" on public.bolaos
  for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "dono gerencia jogos" on public.jogos;
create policy "dono gerencia jogos" on public.jogos
  for all to authenticated
  using (exists (select 1 from public.bolaos b where b.id = bolao_id and b.owner = auth.uid()))
  with check (exists (select 1 from public.bolaos b where b.id = bolao_id and b.owner = auth.uid()));

-- quem não está logado não toca nas tabelas diretamente
revoke all on public.bolaos, public.jogos from anon;
grant select, insert, update, delete on public.bolaos, public.jogos to authenticated;

-- dados do convite (sem token, dono ou jogos)
create or replace function public.get_convite(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', id, 'nome', nome, 'lot', lot, 'conc', conc, 'teim', teim, 'prazo', prazo,
    'preco', preco, 'mx', mx, 'div', div, 'pix', pix, 'adm', adm,
    'expirado', (prazo is not null and now() > prazo))
  from public.bolaos where token = p_token;
$$;

-- participante envia jogos pelo link (sem login)
create or replace function public.enviar_jogos(p_token uuid, p_nome text, p_jogos jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare
  b public.bolaos; j jsonb; d int[]; t int[]; m int;
  lo int; hi int; nmin int; nmax int; total int; ids uuid[] := '{}'; novo uuid;
begin
  select * into b from public.bolaos where token = p_token;
  if not found then raise exception 'convite_invalido'; end if;
  if b.prazo is not null and now() > b.prazo then raise exception 'convite_expirado'; end if;

  p_nome := btrim(coalesce(p_nome, ''));
  if char_length(p_nome) not between 1 and 60 then raise exception 'nome_invalido'; end if;
  if jsonb_typeof(p_jogos) is distinct from 'array' or jsonb_array_length(p_jogos) not between 1 and 10 then
    raise exception 'quantidade_invalida';
  end if;
  select count(*) into total from public.jogos where bolao_id = b.id;
  if total + jsonb_array_length(p_jogos) > 300 then raise exception 'bolao_cheio'; end if;

  select r.lo, r.hi, r.nmin, r.nmax into lo, hi, nmin, nmax from (values
    ('megasena',1,60,6,20), ('lotofacil',1,25,15,20), ('quina',1,80,5,15), ('lotomania',0,99,50,50),
    ('duplasena',1,50,6,15), ('diadesorte',1,31,7,15), ('timemania',1,80,10,10), ('maismilionaria',1,50,6,12)
  ) as r(lot, lo, hi, nmin, nmax) where r.lot = b.lot;
  nmax := least(nmax, coalesce(b.mx, nmax));

  for j in select value from jsonb_array_elements(p_jogos) loop
    if jsonb_typeof(j->'d') is distinct from 'array' then raise exception 'dezenas_invalidas'; end if;
    d := array(select x::int from jsonb_array_elements_text(j->'d') as x order by 1);
    if coalesce(array_length(d,1),0) not between nmin and nmax
       or (select count(distinct x) from unnest(d) as x) <> array_length(d,1)
       or (select min(x) from unnest(d) as x) < lo or (select max(x) from unnest(d) as x) > hi then
      raise exception 'dezenas_invalidas';
    end if;

    t := null; m := null;
    if b.lot = 'maismilionaria' then
      if jsonb_typeof(j->'t') is distinct from 'array' then raise exception 'trevos_invalidos'; end if;
      t := array(select x::int from jsonb_array_elements_text(j->'t') as x order by 1);
      if coalesce(array_length(t,1),0) not between 2 and 6
         or (select count(distinct x) from unnest(t) as x) <> array_length(t,1)
         or (select min(x) from unnest(t) as x) < 1 or (select max(x) from unnest(t) as x) > 6 then
        raise exception 'trevos_invalidos';
      end if;
    end if;
    if b.lot = 'diadesorte' then
      m := (j->>'m')::int;
      if m is null or m not between 0 and 11 then raise exception 'mes_invalido'; end if;
    end if;

    insert into public.jogos (bolao_id, p, d, t, m, src) values (b.id, p_nome, d, t, m, 'link') returning id into novo;
    ids := ids || novo;
  end loop;
  return json_build_object('ok', true, 'ids', ids);
end $$;

revoke all on function public.get_convite(uuid) from public;
revoke all on function public.enviar_jogos(uuid, text, jsonb) from public;
grant execute on function public.get_convite(uuid) to anon, authenticated;
grant execute on function public.enviar_jogos(uuid, text, jsonb) to anon, authenticated;

-- jogos novos aparecem na hora na tela do organizador
do $$ begin
  alter publication supabase_realtime add table public.jogos;
exception when duplicate_object then null; end $$;
