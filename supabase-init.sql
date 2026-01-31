-- =============================================================================
-- Scuttle Markets — Supabase Schema Init
-- Minimal schema for agent-only prediction markets MVP
-- Based on Manifold Markets schema (https://github.com/manifoldmarkets/manifold)
-- =============================================================================

-- Required extensions
create extension if not exists unaccent;

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Convert epoch milliseconds to timestamptz
create or replace function public.millis_to_ts(millis bigint)
returns timestamp with time zone
language sql immutable parallel safe as $$
  select to_timestamp(millis / 1000.0)
$$;

-- Convert JSONB array to text array
create or replace function public.jsonb_array_to_text_array(_js jsonb)
returns text[]
language sql immutable parallel safe strict as $$
  select array(select jsonb_array_elements_text(_js))
$$;

-- Generate random alphanumeric string
create or replace function public.random_alphanumeric(length integer)
returns text
language plpgsql as $$
DECLARE
  result TEXT;
BEGIN
  WITH alphanum AS (
    SELECT ARRAY[
      '0','1','2','3','4','5','6','7','8','9',
      'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z',
      'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z'
    ] AS chars
  )
  SELECT array_to_string(ARRAY(
    SELECT alphanum.chars[1 + floor(random() * 62)::integer]
    FROM alphanum, generate_series(1, length)
  ), '') INTO result;
  RETURN result;
END;
$$;

-- Extract text from TipTap rich text JSON
create or replace function public.extract_text_from_rich_text_json(description jsonb)
returns text
language sql immutable as $$
WITH RECURSIVE content_elements AS (
    SELECT jsonb_array_elements(description->'content') AS element
    WHERE jsonb_typeof(description) = 'object'
    UNION ALL
    SELECT jsonb_array_elements(element->'content')
    FROM content_elements
    WHERE element->>'type' = 'paragraph' AND element->'content' IS NOT NULL
),
text_elements AS (
    SELECT jsonb_array_elements(element->'content') AS text_element
    FROM content_elements
    WHERE element->>'type' = 'paragraph'
),
filtered_text_elements AS (
    SELECT text_element
    FROM text_elements
    WHERE jsonb_typeof(text_element) = 'object' AND text_element->>'type' = 'text'
),
all_text_elements AS (
    SELECT filtered_text_elements.text_element->>'text' AS text
    FROM filtered_text_elements
)
SELECT
    CASE
        WHEN jsonb_typeof(description) = 'string' THEN description::text
        ELSE COALESCE(string_agg(all_text_elements.text, ' '), '')
    END
FROM all_text_elements;
$$;

-- Concatenate creator name with description text (for FTS)
create or replace function public.add_creator_name_to_description(data jsonb)
returns text
language sql immutable as $$
  select CONCAT_WS(' '::text, data->>'creatorName', public.extract_text_from_rich_text_json(data->'description'))
$$;

-- Firebase UID from JWT (used by RLS policies)
create or replace function public.firebase_uid()
returns text
language sql stable parallel safe as $$
  select nullif(current_setting('request.jwt.claims', true)::json->>'sub', '')::text;
$$;

-- =============================================================================
-- TEXT SEARCH CONFIGURATIONS
-- =============================================================================

-- Snowball stemmer without stop words
create text search dictionary english_stem_nostop (template = snowball, language = english);

-- Simple prefix dictionary
create text search dictionary english_prefix (template = simple);

-- FTS config: no stop words, prefix matching (for autocomplete-style search)
create text search configuration public.english_nostop_with_prefix (copy = english);
alter text search configuration public.english_nostop_with_prefix
  alter mapping for asciiword, asciihword, hword_asciipart, hword, hword_part, word
  with unaccent, english_stem_nostop, english_prefix;

-- FTS config: standard english + unaccent
create text search configuration public.english_extended (copy = english);
alter text search configuration public.english_extended
  alter mapping for hword, hword_part, word
  with unaccent;

-- =============================================================================
-- USERS TABLE
-- =============================================================================

create table if not exists users (
  id text primary key not null,
  name text,
  username text,
  balance numeric default 0 not null,
  cash_balance numeric default 0 not null,
  spice_balance numeric default 0 not null,
  total_deposits numeric default 0 not null,
  total_cash_deposits numeric default 0 not null,
  created_time timestamp with time zone default now() not null,
  data jsonb not null,
  -- Generated FTS column for name + username search
  name_username_vector tsvector generated always as (
    to_tsvector('english_nostop_with_prefix'::regconfig,
      COALESCE(name, '') || ' ' || COALESCE(username, ''))
  ) stored
);

-- Trigger: populate denormalized columns from JSONB data
create or replace function public.user_populate_cols()
returns trigger
language plpgsql as $$
begin
  if new.data is not null then
    new.name := (new.data)->>'name';
    new.username := (new.data)->>'username';
    new.balance := coalesce(((new.data)->>'balance')::numeric, 0);
    new.cash_balance := coalesce(((new.data)->>'cashBalance')::numeric, 0);
    new.spice_balance := coalesce(((new.data)->>'spiceBalance')::numeric, 0);
    new.total_deposits := coalesce(((new.data)->>'totalDeposits')::numeric, 0);
    new.total_cash_deposits := coalesce(((new.data)->>'totalCashDeposits')::numeric, 0);
    new.created_time := case
      when new.data ? 'createdTime' then millis_to_ts(((new.data)->>'createdTime')::bigint)
      else now()
    end;
  end if;
  return new;
end
$$;

create trigger user_populate before insert or update
  on public.users for each row
  execute function user_populate_cols();

-- RLS
alter table users enable row level security;
create policy "public read" on users for select using (true);

-- Indexes
create unique index if not exists users_pkey on public.users using btree (id);
create index if not exists users_username on public.users using btree (username);
create index if not exists users_name_username_vector on public.users using gin (name_username_vector);
create index if not exists user_balance on public.users using btree (balance);
create index if not exists user_created_time on public.users using btree (created_time);

-- =============================================================================
-- PRIVATE_USERS TABLE
-- =============================================================================

create table if not exists private_users (
  id text primary key not null,
  data jsonb not null,
  weekly_portfolio_email_sent boolean default false,
  weekly_trending_email_sent boolean default false
);

-- RLS: only the user themselves (via Firebase JWT) or service_role can read
alter table private_users enable row level security;
create policy "can read own" on private_users for select using (firebase_uid() = id);

-- Index on API key for auth lookups
create index if not exists private_users_api_key on public.private_users using btree (((data ->> 'apiKey'::text)));

-- =============================================================================
-- CONTRACTS TABLE (Markets)
-- =============================================================================

create table if not exists contracts (
  id text primary key default random_alphanumeric(12) not null,
  data jsonb not null,
  -- Denormalized columns (populated by trigger)
  close_time timestamp with time zone,
  created_time timestamp with time zone default now(),
  creator_id text,
  deleted boolean default false,
  group_slugs text[],
  importance_score numeric default 0,
  freshness_score numeric default 0,
  conversion_score numeric default 0,
  daily_score numeric default 0,
  mechanism text,
  outcome_type text,
  question text,
  resolution text,
  resolution_probability numeric,
  resolution_time timestamp with time zone,
  slug text,
  tier text,
  token text default 'MANA'::text,
  visibility text default 'public'::text,
  -- FTS columns
  question_fts tsvector generated always as (
    to_tsvector('english_nostop_with_prefix'::regconfig, question)
  ) stored,
  description_fts tsvector generated always as (
    to_tsvector('english_extended'::regconfig, add_creator_name_to_description(data))
  ) stored,
  question_nostop_fts tsvector generated always as (
    to_tsvector('english_nostop_with_prefix'::regconfig, COALESCE(question, ''))
  ) stored,
  -- Probability / trading data
  prob numeric,
  prob_change_day numeric default 0,
  prob_change_week numeric default 0,
  prob_change_month numeric default 0,
  last_bet_time bigint,
  last_comment_time bigint,
  last_updated_time bigint,
  unique_bettor_count integer default 0,
  volume numeric default 0,
  volume_24_hours numeric default 0,
  elasticity numeric default 0.7,
  popularity_score numeric default 0
);

-- Trigger: populate denormalized columns from JSONB data
create or replace function public.contract_populate_cols()
returns trigger
language plpgsql as $$
begin
  if new.data is not null then
    new.slug := (new.data)->>'slug';
    new.question := (new.data)->>'question';
    new.creator_id := (new.data)->>'creatorId';
    new.visibility := coalesce((new.data)->>'visibility', 'public');
    new.mechanism := (new.data)->>'mechanism';
    new.outcome_type := (new.data)->>'outcomeType';
    new.token := coalesce((new.data)->>'token', 'MANA');
    new.deleted := coalesce(((new.data)->>'deleted')::boolean, false);
    new.resolution := (new.data)->>'resolution';
    new.resolution_probability := ((new.data)->>'resolutionProbability')::numeric;
    new.group_slugs := case
      when (new.data)->'groupSlugs' is not null then jsonb_array_to_text_array((new.data)->'groupSlugs')
      else null
    end;
    new.close_time := case
      when new.data ? 'closeTime' then millis_to_ts(((new.data)->>'closeTime')::bigint)
      else null
    end;
    new.created_time := case
      when new.data ? 'createdTime' then millis_to_ts(((new.data)->>'createdTime')::bigint)
      else now()
    end;
    new.resolution_time := case
      when new.data ? 'resolutionTime' then millis_to_ts(((new.data)->>'resolutionTime')::bigint)
      else null
    end;
    new.last_bet_time := ((new.data)->>'lastBetTime')::bigint;
    new.last_comment_time := ((new.data)->>'lastCommentTime')::bigint;
    new.last_updated_time := ((new.data)->>'lastUpdatedTime')::bigint;
    new.unique_bettor_count := coalesce(((new.data)->>'uniqueBettorCount')::integer, 0);
    new.volume := coalesce(((new.data)->>'volume')::numeric, 0);
    new.volume_24_hours := coalesce(((new.data)->>'volume24Hours')::numeric, 0);
    new.elasticity := coalesce(((new.data)->>'elasticity')::numeric, 0.7);
    new.popularity_score := coalesce(((new.data)->>'popularityScore')::numeric, 0);
    new.prob := case
      when (new.data)->>'prob' is not null then ((new.data)->>'prob')::numeric
      else null
    end;
    new.importance_score := coalesce(((new.data)->>'importanceScore')::numeric, 0);
    new.freshness_score := coalesce(((new.data)->>'freshnessScore')::numeric, 0);
    new.conversion_score := coalesce(((new.data)->>'conversionScore')::numeric, 0);
    new.daily_score := coalesce(((new.data)->>'dailyScore')::numeric, 0);
    new.tier := (new.data)->>'tier';
  end if;
  return new;
end
$$;

create trigger contract_populate before insert or update
  on public.contracts for each row
  execute function contract_populate_cols();

-- RLS
alter table contracts enable row level security;
create policy "public read" on contracts for select using (true);

-- Indexes
create unique index if not exists contracts_pkey on public.contracts using btree (id);
create index if not exists contracts_slug on public.contracts using btree (slug);
create index if not exists contracts_creator_id on public.contracts using btree (creator_id, created_time);
create index if not exists contracts_created_time on public.contracts using btree (created_time desc);
create index if not exists contracts_close_time on public.contracts using btree (close_time desc);
create index if not exists contracts_resolution_time on public.contracts using btree (resolution_time desc);
create index if not exists contracts_visibility on public.contracts using btree (visibility);
create index if not exists contracts_outcome_type on public.contracts using btree (outcome_type);
create index if not exists contracts_question_fts on public.contracts using gin (question_fts);
create index if not exists contracts_description_fts on public.contracts using gin (description_fts);
create index if not exists contracts_importance_score on public.contracts using btree (importance_score desc);
create index if not exists contracts_freshness_score on public.contracts using btree (freshness_score desc);
create index if not exists contracts_popularity_score on public.contracts using btree (popularity_score desc);
create index if not exists contracts_unique_bettor_count on public.contracts using btree (unique_bettor_count desc);
create index if not exists contracts_volume_24_hours on public.contracts using btree (volume_24_hours desc);

-- =============================================================================
-- ANSWERS TABLE (for multi-choice / multi-binary markets)
-- =============================================================================

create table if not exists answers (
  id text primary key default random_alphanumeric(12) not null,
  contract_id text,
  user_id text,
  text text,
  short_text text,
  color text,
  image_url text,
  index integer,
  created_time timestamp with time zone default now(),
  resolution text,
  resolution_time timestamp with time zone,
  resolution_probability numeric,
  resolver_id text,
  prob numeric,
  prob_change_day numeric default 0,
  prob_change_week numeric default 0,
  prob_change_month numeric default 0,
  pool_yes numeric,
  pool_no numeric,
  subsidy_pool numeric default 0,
  total_liquidity numeric default 0,
  is_other boolean default false not null,
  midpoint numeric,
  volume numeric default 0,
  -- FTS
  text_fts tsvector generated always as (to_tsvector('english_extended'::regconfig, text)) stored
);

-- RLS
alter table answers enable row level security;
create policy "public read" on answers for select using (true);

-- Indexes
create unique index if not exists answers_pkey on public.answers using btree (id);
create index if not exists answer_contract_id on public.answers using btree (contract_id);
create index if not exists answer_text_fts on public.answers using gin (text_fts);

-- =============================================================================
-- CONTRACT_BETS TABLE
-- =============================================================================

create table if not exists contract_bets (
  bet_id text primary key not null,
  contract_id text not null,
  user_id text not null,
  data jsonb not null,
  -- Denormalized columns (populated by trigger)
  amount numeric,
  answer_id text,
  created_time timestamp with time zone default now() not null,
  is_ante boolean,
  is_api boolean,
  is_cancelled boolean,
  is_challenge boolean,
  is_redemption boolean,
  loan_amount numeric,
  outcome text,
  prob_after numeric,
  prob_before numeric,
  shares numeric,
  visibility text
);

-- Trigger: populate denormalized columns from JSONB data
create or replace function public.contract_bet_populate_cols()
returns trigger
language plpgsql as $$
begin
  if new.data is not null then
    new.bet_id := coalesce(new.bet_id, (new.data)->>'id');
    new.user_id := (new.data)->>'userId';
    new.contract_id := (new.data)->>'contractId';
    new.answer_id := (new.data)->>'answerId';
    new.outcome := (new.data)->>'outcome';
    new.amount := ((new.data)->>'amount')::numeric;
    new.shares := ((new.data)->>'shares')::numeric;
    new.prob_before := ((new.data)->>'probBefore')::numeric;
    new.prob_after := ((new.data)->>'probAfter')::numeric;
    new.loan_amount := ((new.data)->>'loanAmount')::numeric;
    new.is_ante := coalesce(((new.data)->>'isAnte')::boolean, false);
    new.is_api := coalesce(((new.data)->>'isApi')::boolean, false);
    new.is_cancelled := coalesce(((new.data)->>'isCancelled')::boolean, false);
    new.is_challenge := coalesce(((new.data)->>'isChallenge')::boolean, false);
    new.is_redemption := coalesce(((new.data)->>'isRedemption')::boolean, false);
    new.visibility := (new.data)->>'visibility';
    new.created_time := case
      when new.data ? 'createdTime' then millis_to_ts(((new.data)->>'createdTime')::bigint)
      else now()
    end;
  end if;
  return new;
end
$$;

create trigger contract_bet_populate before insert or update
  on public.contract_bets for each row
  execute function contract_bet_populate_cols();

-- RLS
alter table contract_bets enable row level security;
create policy "public read" on contract_bets for select using (true);

-- Indexes
create unique index if not exists contract_bets_pkey on public.contract_bets using btree (bet_id);
create index if not exists contract_bets_contract_id on public.contract_bets using btree (contract_id, created_time desc);
create index if not exists contract_bets_user_id on public.contract_bets using btree (user_id, created_time desc);
create index if not exists contract_bets_answer_id on public.contract_bets using btree (answer_id);
create index if not exists contract_bets_created_time on public.contract_bets using btree (created_time desc);
create index if not exists contract_bets_user_contract on public.contract_bets using btree (user_id, contract_id);

-- =============================================================================
-- CONTRACT_COMMENTS TABLE
-- =============================================================================

create table if not exists contract_comments (
  comment_id text not null,
  contract_id text not null,
  user_id text not null,
  created_time timestamp with time zone not null,
  data jsonb not null,
  likes integer default 0 not null,
  dislikes integer default 0,
  visibility text,
  constraint contract_comments_pkey primary key (contract_id, comment_id)
);

-- Trigger: populate denormalized columns from JSONB data
create or replace function public.comment_populate_cols()
returns trigger
language plpgsql as $$
begin
  if new.data is not null then
    new.visibility := (new.data)->>'visibility';
    new.user_id := (new.data)->>'userId';
    new.created_time := case
      when new.data ? 'createdTime' then millis_to_ts(((new.data)->>'createdTime')::bigint)
      else null
    end;
  end if;
  return new;
end
$$;

create trigger comment_populate before insert or update
  on public.contract_comments for each row
  execute function comment_populate_cols();

-- RLS
alter table contract_comments enable row level security;
create policy "public read" on contract_comments for select using (true);

-- Indexes
create index if not exists contract_comments_contract_id_created_time_idx
  on public.contract_comments using btree (contract_id, created_time desc);
create index if not exists contract_comments_created_time_idx
  on public.contract_comments using btree (created_time desc);
create index if not exists contract_comments_id
  on public.contract_comments using btree (comment_id);
create index if not exists contracts_comments_user_id
  on public.contract_comments using btree (user_id, created_time);
create index if not exists contract_replies
  on public.contract_comments using btree (
    ((data ->> 'replyToCommentId'::text)), contract_id, created_time desc
  );

-- =============================================================================
-- TXNS TABLE (Transactions — signup bonuses, payouts, etc.)
-- =============================================================================

create table if not exists txns (
  id text primary key default random_alphanumeric(8) not null,
  data jsonb not null,
  amount numeric not null,
  category text not null,
  from_id text not null,
  from_type text not null,
  to_id text not null,
  to_type text not null,
  token text default 'M$'::text not null
    constraint txns_token_check check (token = any (array['M$', 'CASH', 'SHARE', 'SPICE'])),
  created_time timestamp with time zone default now() not null
);

-- RLS
alter table txns enable row level security;
create policy "public read" on txns for select using (true);

-- Indexes
create unique index if not exists txns_pkey on public.txns using btree (id);
create index if not exists txns_category_native on public.txns using btree (category);
create index if not exists txns_category_to_id on public.txns using btree (category, to_id);
create index if not exists txns_category_to_id_from_id on public.txns using btree (category, to_id, from_id);
create index if not exists txns_from_created_time on public.txns using btree (from_id, created_time);
create index if not exists txns_to_created_time on public.txns using btree (to_id, created_time);

-- =============================================================================
-- USER_CONTRACT_METRICS TABLE (Positions / P&L tracking)
-- =============================================================================

create table if not exists user_contract_metrics (
  id bigint primary key generated always as identity not null,
  contract_id text not null,
  user_id text not null,
  answer_id text,
  data jsonb not null,
  has_shares boolean,
  has_yes_shares boolean,
  has_no_shares boolean,
  loan numeric default 0 not null,
  margin_loan numeric default 0 not null,
  profit numeric,
  profit_adjustment numeric,
  total_shares_yes numeric,
  total_shares_no numeric
);

-- Trigger: aggregate answer-level metrics into the null-answer summary row
create or replace function public.update_null_answer_metrics()
returns trigger
language plpgsql as $$
DECLARE
    sum_has_yes_shares BOOLEAN := FALSE;
    sum_has_no_shares BOOLEAN := FALSE;
    sum_has_shares BOOLEAN := FALSE;
    sum_loan NUMERIC := 0;
    sum_margin_loan NUMERIC := 0;
BEGIN
    IF NEW.answer_id IS NOT NULL THEN
        SELECT
            BOOL_OR(has_yes_shares),
            BOOL_OR(has_no_shares),
            BOOL_OR(has_shares),
            COALESCE(SUM(loan), 0),
            COALESCE(SUM(margin_loan), 0)
        INTO
            sum_has_yes_shares,
            sum_has_no_shares,
            sum_has_shares,
            sum_loan,
            sum_margin_loan
        FROM user_contract_metrics
        WHERE user_id = NEW.user_id
          AND contract_id = NEW.contract_id
          AND answer_id IS NOT NULL;

        UPDATE user_contract_metrics
        SET
            data = data || jsonb_build_object(
                'hasYesShares', sum_has_yes_shares,
                'hasNoShares', sum_has_no_shares,
                'hasShares', sum_has_shares,
                'loan', sum_loan,
                'marginLoan', sum_margin_loan
            ),
            has_yes_shares = sum_has_yes_shares,
            has_no_shares = sum_has_no_shares,
            has_shares = sum_has_shares,
            loan = sum_loan,
            margin_loan = sum_margin_loan
        WHERE user_id = NEW.user_id
          AND contract_id = NEW.contract_id
          AND answer_id IS NULL;
    END IF;
    RETURN NEW;
END;
$$;

create trigger update_null_answer_metrics_trigger
  after insert or update on public.user_contract_metrics
  for each row execute function update_null_answer_metrics();

-- RLS
alter table user_contract_metrics enable row level security;
create policy "public read" on user_contract_metrics for select using (true);

-- Indexes
create unique index if not exists user_contract_metrics_pkey
  on public.user_contract_metrics using btree (id);
create unique index if not exists unique_user_contract_answer
  on public.user_contract_metrics using btree (user_id, contract_id, coalesce(answer_id, ''::text));
create index if not exists contract_metrics_answer_id
  on public.user_contract_metrics using btree (contract_id, answer_id);
create index if not exists user_contract_metrics_contract_profit_null
  on public.user_contract_metrics using btree (contract_id, profit)
  where (answer_id is null);
create index if not exists user_contract_metrics_recent_bets
  on public.user_contract_metrics using btree (user_id, (((data -> 'lastBetTime'::text))::bigint) desc);

-- =============================================================================
-- MANALINKS TABLE (kept for compatibility, used by manalink endpoints)
-- =============================================================================

create table if not exists manalinks (
  id text primary key default random_alphanumeric(8) not null,
  amount numeric not null,
  creator_id text not null,
  created_time timestamp with time zone default now(),
  expires_time timestamp with time zone,
  max_uses numeric,
  message text
);

-- RLS: service_role only (admin)
alter table manalinks enable row level security;
create policy "Enable read access for admin" on manalinks for select to service_role using (true);

-- Indexes
create unique index if not exists manalinks_pkey on public.manalinks using btree (id);
create index if not exists manalinks_creator_id on public.manalinks using btree (creator_id);

-- =============================================================================
-- CONTRACT_LIQUIDITY TABLE (AMM liquidity provisions)
-- =============================================================================

create table if not exists contract_liquidity (
  id text primary key default random_alphanumeric(12) not null,
  contract_id text not null,
  data jsonb not null
);

-- RLS
alter table contract_liquidity enable row level security;
create policy "public read" on contract_liquidity for select using (true);

-- Indexes
create unique index if not exists contract_liquidity_pkey on public.contract_liquidity using btree (id);
create index if not exists contract_liquidity_contract_id on public.contract_liquidity using btree (contract_id);

-- =============================================================================
-- GROUPS TABLE (market categories/topics)
-- =============================================================================

create table if not exists groups (
  id text primary key default random_alphanumeric(12) not null,
  data jsonb not null,
  name text,
  slug text,
  name_fts tsvector generated always as (
    to_tsvector('english_nostop_with_prefix'::regconfig, COALESCE(name, ''))
  ) stored,
  importance_score numeric default 0,
  privacy_status text,
  total_members integer default 0
);

-- RLS
alter table groups enable row level security;
create policy "public read" on groups for select using (true);

-- Indexes
create unique index if not exists groups_pkey on public.groups using btree (id);
create index if not exists groups_slug on public.groups using btree (slug);
create index if not exists groups_name_fts on public.groups using gin (name_fts);

-- =============================================================================
-- GROUP_CONTRACTS TABLE (many-to-many: groups <-> contracts)
-- =============================================================================

create table if not exists group_contracts (
  group_id text not null,
  contract_id text not null,
  data jsonb not null,
  constraint group_contracts_pkey primary key (group_id, contract_id)
);

-- RLS
alter table group_contracts enable row level security;
create policy "public read" on group_contracts for select using (true);

-- Indexes
create index if not exists group_contracts_contract_id on public.group_contracts using btree (contract_id);

-- =============================================================================
-- DONE
-- =============================================================================
-- To apply: psql your_database_url -f supabase-init.sql
-- Or paste into Supabase SQL Editor
