-- ============================================================
-- KMT 人事管理システム — データベース一括セットアップ
--   ・全テーブル作成
--   ・権限レベル（ゲスト／社員／管理者／全体管理）
--   ・RLS（サーバー側の権限チェック）
--   ・許可リストに無いメールの新規登録を拒否するトリガー
-- 何度実行しても安全です（再実行可）。
-- ============================================================

create extension if not exists pgcrypto;

-- 1) テーブル -------------------------------------------------------
create table if not exists public.allowed_users (
  email        text primary key,
  display_name text default '',
  role         text not null default '社員',
  added_at     timestamptz not null default now()
);
alter table public.allowed_users add column if not exists display_name text default '';
alter table public.allowed_users add column if not exists role text not null default '社員';
alter table public.allowed_users drop constraint if exists allowed_users_role_chk;
alter table public.allowed_users add constraint allowed_users_role_chk
  check (role in ('ゲスト','社員','管理者','全体管理'));

create table if not exists public.departments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  sort_order int default 0
);

create table if not exists public.doc_templates (
  id         text primary key,
  stage      text not null,
  name       text not null,
  tags       text[] not null default '{}',
  note       text default '',
  sort_order int default 0
);

create table if not exists public.employees (
  id                  uuid primary key default gen_random_uuid(),
  emp_no              text default '',
  status              text default '在籍',
  name_kanji          text default '',
  name_kana           text default '',
  name_roma           text default '',
  birth_date          date,
  gender              text default '',
  nationality         text default '',
  is_foreign          boolean default false,
  employment_type     text default '正社員',
  department          text default '',
  position            text default '',
  hire_date           date,
  probation_end       date,
  contract_end        date,
  resign_date         date,
  email               text default '',
  phone               text default '',
  postal_code         text default '',
  address             text default '',
  emergency_name      text default '',
  emergency_relation  text default '',
  emergency_phone     text default '',
  social_ins          boolean default false,
  emp_ins_no          text default '',
  pension_no          text default '',
  my_number_collected boolean default false,
  zairyu_status       text default '',
  zairyu_card_no      text default '',
  zairyu_expiry       date,
  passport_no         text default '',
  passport_expiry     date,
  toritsugi_expiry    date,
  notes               text default '',
  created_at          timestamptz not null default now()
);
-- 既存のデータベースにも後から足せるようにしておく（給与システムの従業員情報CSVに郵便番号がある）
alter table public.employees add column if not exists postal_code text default '';
-- 所属＝雇用契約を結んでいる法人、勤務＝実際に働いている法人（兼務・出向で異なることがある）
alter table public.employees add column if not exists affiliation text default '';
alter table public.employees add column if not exists workplace   text default '';
-- 現住所に住み始めた日（住所変更時の「変更日」）
alter table public.employees add column if not exists address_since date;

-- 住所変更履歴。住所を変えて保存すると、変更前の住所がここに1行残る。
-- valid_from＝その住所に住み始めた日（分かる範囲で）、valid_to＝引っ越した日
create table if not exists public.employee_address_history (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  postal_code text default '',
  address     text default '',
  valid_from  date,
  valid_to    date,
  recorded_by text default '',
  created_at  timestamptz not null default now()
);
create index if not exists emp_addr_hist_emp_idx on public.employee_address_history (employee_id, valid_to desc);

create table if not exists public.employee_docs (
  employee_id uuid not null references public.employees(id) on delete cascade,
  doc_id      text not null,
  status      text default '未依頼',
  date        date,
  note        text default '',
  primary key (employee_id, doc_id)
);

create table if not exists public.evaluations (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid references public.employees(id) on delete cascade,
  period        text default '',
  evaluator     text default '',
  status        text default '目標設定',
  role          text default '紹介営業',
  kpis          jsonb default '[]'::jsonb,
  comps         jsonb default '[]'::jsonb,
  atts          jsonb default '[]'::jsonb,
  sd_reason     text default '',
  mid_review    text default '',
  final_meeting text default '',
  emp_comment   text default '',
  goals         jsonb default '[]'::jsonb,
  self_score    text default '',
  mgr_score     text default '',
  final_grade   text default '',
  comment       text default ''
);

-- 退職者数のように「少ないほど良い」KPIを正しく評価するための区分
-- （達成率を 目標÷実績 で計算する）
create table if not exists public.kpis (
  id          uuid primary key default gen_random_uuid(),
  period      text default '',
  scope       text default '全社',   -- 全社 / 部署 / チーム（国籍別）/ 個人
  employee_id uuid references public.employees(id) on delete set null,
  dept        text default '',
  name        text default '',
  unit        text default '',
  target      text default '',
  records     jsonb default '[]'::jsonb,
  notes       text default ''
);
alter table public.kpis add column if not exists lower_better boolean not null default false;

create table if not exists public.assets (
  id            uuid primary key default gen_random_uuid(),
  asset_no      text default '',
  category      text default 'PC',
  name          text default '',
  serial        text default '',
  purchase_date date,
  price         text default '',
  status        text default '在庫',
  assigned_to   uuid references public.employees(id) on delete set null,
  lend_date     date,
  return_date   date,
  notes         text default ''
);

-- スキル管理（カオナビ型）：スキルマスタ＋社員別レベル
create table if not exists public.skill_defs (
  id          text primary key,
  category    text not null,
  name        text not null,
  description text default '',
  sort_order  int default 0
);
-- 英語併記用（外国籍スタッフ向け。アプリの「スキルマスタ」から編集可）
alter table public.skill_defs add column if not exists name_en        text default '';
alter table public.skill_defs add column if not exists description_en text default '';
alter table public.skill_defs add column if not exists category_en    text default '';
-- スキルごとの具体的タスク [{jp,en},...]。初期データはアプリの
-- 「スキルマスタ > 初期テンプレートに戻す」で投入される（DEFAULT_SKILL_TASKS）
alter table public.skill_defs add column if not exists tasks jsonb not null default '[]'::jsonb;

create table if not exists public.employee_skills (
  employee_id uuid not null references public.employees(id) on delete cascade,
  skill_id    text not null references public.skill_defs(id) on delete cascade,
  level       int not null default 0 check (level between 0 and 5),
  note        text default '',
  updated_at  timestamptz not null default now(),
  primary key (employee_id, skill_id)
);
-- タスクごとの評価 {taskId: 1〜5}。スキル本体の点数はこの平均で決まる
-- （level 列には四捨五入した平均が入る）
alter table public.employee_skills add column if not exists task_levels jsonb not null default '{}'::jsonb;

-- 社内の許可証管理（登録支援機関・有料/無料職業紹介事業など会社としての許認可）
-- docs は [{name,note,done}] の配列。renew_rule は 'ssw' / 'shokai' / 空（手入力）
create table if not exists public.licenses (
  id           uuid primary key default gen_random_uuid(),
  name         text not null default '',
  authority    text default '',
  license_no   text default '',
  status       text default '有効',
  valid_from   date,
  valid_to     date,
  renew_rule   text default '',
  renew_start  date,
  renew_end    date,
  prep_start   date,
  renew_period text default '',
  fee          text default '',
  docs         jsonb not null default '[]'::jsonb,
  ref_url      text default '',
  drive_url    text default '',
  notes        text default '',
  sort_order   int default 0,
  created_at   timestamptz not null default now()
);

-- GLT月報：案件記録（1人1行の台帳）と、月次合計・チーム目標
-- 月報は case_records から自動集計する。記録が無い月は monthly_reports を使う。
create table if not exists public.case_records (
  id          uuid primary key default gen_random_uuid(),
  team        text not null,
  entry_date  date not null,
  seq_no      int,
  person_name text not null default '',
  person_no   text default '',
  company     text default '',
  category    text not null,   -- 紹介／新規採用／元実習生／入社／退職
  subtype     text default '', -- 認定／国内変更／配属／切替／転職／帰国／キャンセル
  staff       text default '',
  note        text default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists case_records_idx on public.case_records (team, entry_date);

create table if not exists public.monthly_reports (
  id         uuid primary key default gen_random_uuid(),
  year       int  not null,
  month      int  not null check (month between 1 and 12),
  team       text not null,
  shokai     int not null default 0,
  shinki     int not null default 0,
  jisshusei  int not null default 0,
  nyusha     int not null default 0,
  taishoku   int not null default 0,
  cancel     int not null default 0,
  achieved   int,   -- 達成数。空なら 新規採用＋元実習生 で自動計算
  note       text default '',
  updated_at timestamptz not null default now(),
  unique (year, month, team)
);

create table if not exists public.team_targets (
  id             uuid primary key default gen_random_uuid(),
  year           int  not null,
  team           text not null,
  existing_count int,
  annual_target  int not null default 0,
  q1 int not null default 0, q2 int not null default 0,
  q3 int not null default 0, q4 int not null default 0,
  unique (year, team)
);

-- SELFing（役割と貢献の自己申告。アシビズ参考）
-- 役割マスタ／期ごとの申告（1人1期1枚）／申告内の役割
create table if not exists public.role_master (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  axis_default   text not null default '顧客満足',
  skill_category text default '',
  sort_order     int default 0
);
create table if not exists public.selfing_reports (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references public.employees(id) on delete cascade,
  period        text not null,
  status        text not null default '入力中',
  capacity      int,
  capacity_note text default '',
  self_comment  text default '',
  mgr_comment   text default '',
  submitted_at  timestamptz,
  reviewed_at   timestamptz,
  updated_at    timestamptz not null default now(),
  unique (employee_id, period)
);
create table if not exists public.selfing_roles (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.selfing_reports(id) on delete cascade,
  role_name   text not null,
  axis        text not null default '顧客満足',
  weight      int  not null default 0 check (weight between 0 and 100),
  self_score  int check (self_score between 1 and 5),
  self_result text default '',
  mgr_score   int check (mgr_score between 1 and 5),
  mgr_note    text default '',
  sort_order  int default 0
);

-- 役職別の期待スキル（達成率の分母）と、マンダラチャート（81マス目標）
create table if not exists public.role_skill_targets (
  id       uuid primary key default gen_random_uuid(),
  role     text not null,
  skill_id text not null references public.skill_defs(id) on delete cascade,
  target   int  not null check (target between 1 and 5),
  unique (role, skill_id)
);
create table if not exists public.mandala_charts (
  id          uuid primary key default gen_random_uuid(),
  scope       text not null default 'personal',
  employee_id uuid references public.employees(id) on delete cascade,
  period      text not null,
  center      text not null default '',
  themes      jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now()
);
create unique index if not exists mandala_company_uidx  on public.mandala_charts (period) where scope='company';
create unique index if not exists mandala_personal_uidx on public.mandala_charts (employee_id, period) where scope='personal';

-- ジョブディスクリプション（職務チェック）
-- jd_items＝業務項目のマスタ（社内のジョブディスクリプション2023年版が出発点）
-- jd_checks＝本人が期ごとに付ける 〇／△／× の記録
create table if not exists public.jd_items (
  id         uuid primary key default gen_random_uuid(),
  dept       text default '',               -- 営業部 ／（2023年版）など
  block      text not null,                 -- 大分類（2023年版は A/B/C/D、2026年版は見出しそのもの）
  subdesk    text default '',               -- サブデスク（大分類の中の小分け）
  track      text default '共通',            -- 新規営業／企業担当／共通（共通はどちらの担当にも出る）
  item       text not null,
  skill_id   text references public.skill_defs(id) on delete set null,
  standard   text default '',               -- 評価内容（「〇」と言える基準）
  metric     text default '',               -- 実績として数えるもの
  target     text default '',               -- 目安の数字
  legal      text default '',               -- 法令の根拠（義務的支援①、職業紹介：事業報告書 など）
  flag       text default '',               -- '' | old（制度が変わった）| chk（社内で要確認）| new（追加案）
  note       text default '',
  active     boolean not null default true,
  sort_order int default 0
);
-- 既存のデータベースにも後から足せるようにしておく
alter table public.jd_items add column if not exists dept     text default '';
alter table public.jd_items add column if not exists subdesk  text default '';
alter table public.jd_items add column if not exists track    text default '共通';
alter table public.jd_items add column if not exists standard text default '';
alter table public.jd_items add column if not exists metric   text default '';
alter table public.jd_items add column if not exists target   text default '';
alter table public.jd_items add column if not exists legal    text default '';

-- 実績の記録（期ごとに1項目1つ）。実績指標が入っている項目にだけ入力欄が出る。
create table if not exists public.jd_metrics (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  period      text not null,
  item_id     uuid not null references public.jd_items(id) on delete cascade,
  value       numeric,
  note        text default '',
  updated_at  timestamptz not null default now(),
  unique (employee_id, period, item_id)
);

-- 誰がどの職種を担っているか。営業部は新規営業・企業担当のどちらか、または両方（兼任）
create table if not exists public.jd_assignments (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  dept        text not null,
  track       text not null,
  unique (employee_id, dept, track)
);
create table if not exists public.jd_checks (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  period      text not null,
  item_id     uuid not null references public.jd_items(id) on delete cascade,
  mark        text not null check (mark in ('〇','△','×')),
  updated_at  timestamptz not null default now(),
  unique (employee_id, period, item_id)
);

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- 2) 権限判定の関数 -------------------------------------------------
--    security definer にすることで allowed_users のRLSと再帰しない
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from public.allowed_users
      where lower(email) = lower(auth.jwt() ->> 'email') limit 1),
    'ゲスト');
$$;

create or replace function public.my_rank()
returns int language sql stable security definer set search_path = public as $$
  select case public.my_role()
    when '全体管理' then 3
    when '管理者'   then 2
    when '社員'     then 1
    else 0 end;
$$;

-- 未ログイン(anon)からRPCで呼べないようにし、ログイン済みにだけ許可する
revoke all on function public.my_role() from public, anon;
revoke all on function public.my_rank() from public, anon;
grant execute on function public.my_role() to authenticated;
grant execute on function public.my_rank() to authenticated;

-- 3) 許可リストに無いメールの新規登録を拒否 --------------------------
create or replace function public.enforce_allowed_signup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.allowed_users where lower(email) = lower(new.email)
  ) then
    raise exception 'signup_not_allowed';
  end if;
  return new;
end $$;

drop trigger if exists enforce_allowed_signup_trg on auth.users;
create trigger enforce_allowed_signup_trg
  before insert on auth.users
  for each row execute function public.enforce_allowed_signup();

-- トリガー専用なのでRPC経由では呼べないようにする（トリガー実行に EXECUTE 権限は不要）
revoke all on function public.enforce_allowed_signup() from public, anon, authenticated;

-- 4) RLS ------------------------------------------------------------
alter table public.allowed_users  enable row level security;
alter table public.departments    enable row level security;
alter table public.doc_templates  enable row level security;
alter table public.employees      enable row level security;
alter table public.employee_docs  enable row level security;
alter table public.evaluations    enable row level security;
alter table public.kpis           enable row level security;
alter table public.assets         enable row level security;

-- allowed_users：閲覧＝自分の行（管理者以上は全員）／変更＝全体管理のみ
drop policy if exists kmt_au_select on public.allowed_users;
drop policy if exists kmt_au_insert on public.allowed_users;
drop policy if exists kmt_au_update on public.allowed_users;
drop policy if exists kmt_au_delete on public.allowed_users;
create policy kmt_au_select on public.allowed_users for select to authenticated
  using (public.my_rank() >= 2 or lower(email) = lower(auth.jwt() ->> 'email'));
create policy kmt_au_insert on public.allowed_users for insert to authenticated
  with check (public.my_rank() >= 3);
create policy kmt_au_update on public.allowed_users for update to authenticated
  using (public.my_rank() >= 3) with check (public.my_rank() >= 3);
create policy kmt_au_delete on public.allowed_users for delete to authenticated
  using (public.my_rank() >= 3);

-- employees：管理者以上は全員／社員は自分の行のみ／ゲストは不可
drop policy if exists kmt_emp_select on public.employees;
drop policy if exists kmt_emp_insert on public.employees;
drop policy if exists kmt_emp_update on public.employees;
drop policy if exists kmt_emp_delete on public.employees;
create policy kmt_emp_select on public.employees for select to authenticated
  using (public.my_rank() >= 2
         or (public.my_rank() = 1 and lower(coalesce(email,'')) = lower(auth.jwt() ->> 'email')));
create policy kmt_emp_insert on public.employees for insert to authenticated
  with check (public.my_rank() >= 2);
create policy kmt_emp_update on public.employees for update to authenticated
  using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
create policy kmt_emp_delete on public.employees for delete to authenticated
  using (public.my_rank() >= 2);

-- employee_docs / evaluations：社員は自分の行のみ閲覧
do $$
declare t text;
begin
  foreach t in array array['employee_docs','evaluations'] loop
    execute format('drop policy if exists kmt_%s_select on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_insert on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_update on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_delete on public.%I', t, t);
    execute format($f$create policy kmt_%s_select on public.%I for select to authenticated
      using (public.my_rank() >= 2
             or (public.my_rank() = 1 and employee_id in (select id from public.employees)))$f$, t, t);
    execute format('create policy kmt_%s_insert on public.%I for insert to authenticated with check (public.my_rank() >= 2)', t, t);
    execute format('create policy kmt_%s_update on public.%I for update to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2)', t, t);
    execute format('create policy kmt_%s_delete on public.%I for delete to authenticated using (public.my_rank() >= 2)', t, t);
  end loop;
end $$;

-- kpis：社員は全社・部署KPI＋自分の個人KPIのみ
drop policy if exists kmt_kpi_select on public.kpis;
drop policy if exists kmt_kpi_insert on public.kpis;
drop policy if exists kmt_kpi_update on public.kpis;
drop policy if exists kmt_kpi_delete on public.kpis;
create policy kmt_kpi_select on public.kpis for select to authenticated
  using (public.my_rank() >= 2
         or (public.my_rank() = 1 and (employee_id is null or employee_id in (select id from public.employees))));
create policy kmt_kpi_insert on public.kpis for insert to authenticated
  with check (public.my_rank() >= 2);
create policy kmt_kpi_update on public.kpis for update to authenticated
  using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
create policy kmt_kpi_delete on public.kpis for delete to authenticated
  using (public.my_rank() >= 2);

-- assets：管理者以上のみ
drop policy if exists kmt_as_select on public.assets;
drop policy if exists kmt_as_insert on public.assets;
drop policy if exists kmt_as_update on public.assets;
drop policy if exists kmt_as_delete on public.assets;
create policy kmt_as_select on public.assets for select to authenticated using (public.my_rank() >= 2);
create policy kmt_as_insert on public.assets for insert to authenticated with check (public.my_rank() >= 2);
create policy kmt_as_update on public.assets for update to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
create policy kmt_as_delete on public.assets for delete to authenticated using (public.my_rank() >= 2);

-- departments / doc_templates：閲覧は社員以上／変更は管理者以上
do $$
declare t text;
begin
  foreach t in array array['departments','doc_templates'] loop
    execute format('drop policy if exists kmt_%s_select on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_insert on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_update on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_delete on public.%I', t, t);
    execute format('create policy kmt_%s_select on public.%I for select to authenticated using (public.my_rank() >= 1)', t, t);
    execute format('create policy kmt_%s_insert on public.%I for insert to authenticated with check (public.my_rank() >= 2)', t, t);
    execute format('create policy kmt_%s_update on public.%I for update to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2)', t, t);
    execute format('create policy kmt_%s_delete on public.%I for delete to authenticated using (public.my_rank() >= 2)', t, t);
  end loop;
end $$;

-- skill_defs：閲覧は社員以上／変更は管理者以上
alter table public.skill_defs enable row level security;
drop policy if exists kmt_sd_select on public.skill_defs;
drop policy if exists kmt_sd_insert on public.skill_defs;
drop policy if exists kmt_sd_update on public.skill_defs;
drop policy if exists kmt_sd_delete on public.skill_defs;
create policy kmt_sd_select on public.skill_defs for select to authenticated using (public.my_rank() >= 1);
create policy kmt_sd_insert on public.skill_defs for insert to authenticated with check (public.my_rank() >= 2);
create policy kmt_sd_update on public.skill_defs for update to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
create policy kmt_sd_delete on public.skill_defs for delete to authenticated using (public.my_rank() >= 2);

-- employee_skills：社員は自分の行のみ閲覧／変更は管理者以上
alter table public.employee_skills enable row level security;
drop policy if exists kmt_es_select on public.employee_skills;
drop policy if exists kmt_es_insert on public.employee_skills;
drop policy if exists kmt_es_update on public.employee_skills;
drop policy if exists kmt_es_delete on public.employee_skills;
create policy kmt_es_select on public.employee_skills for select to authenticated
  using (public.my_rank() >= 2
         or (public.my_rank() = 1 and employee_id in (select id from public.employees)));
create policy kmt_es_insert on public.employee_skills for insert to authenticated with check (public.my_rank() >= 2);
create policy kmt_es_update on public.employee_skills for update to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
create policy kmt_es_delete on public.employee_skills for delete to authenticated using (public.my_rank() >= 2);

-- 4b) スキルの初期テンプレート（空のときだけ投入・再実行安全） --------
insert into public.skill_defs (id, category, category_en, name, name_en, description, description_en, sort_order)
select * from (values
 ('s01','語学・コミュニケーション','Language & Communication','日本語（ビジネス）','Business Japanese','会議・文書・電話応対レベル','Meetings, documents, phone support',1),
 ('s02','語学・コミュニケーション','Language & Communication','英語','English','業務コミュニケーションレベル','Business communication level',2),
 ('s03','語学・コミュニケーション','Language & Communication','多文化コミュニケーション','Cross-cultural Communication','国籍・文化の異なる相手との調整力','Coordinating across nationalities and cultures',3),
 ('s10','紹介営業','Recruitment Sales','新規開拓・アポ獲得','Prospecting & Appointment Setting','','',10),
 ('s11','紹介営業','Recruitment Sales','求人ヒアリング・提案','Job Requirement Analysis & Proposal','','',11),
 ('s12','紹介営業','Recruitment Sales','クロージング・条件交渉','Closing & Terms Negotiation','','',12),
 ('s13','紹介営業','Recruitment Sales','顧客関係維持','Client Relationship Management','既存顧客フォロー・リピート獲得','Follow-up and repeat business',13),
 ('s20','支援業務','Support Services','入管手続き・申請書類','Immigration Procedures & Applications','在留資格の申請・更新・届出','Status applications, renewals, notifications',20),
 ('s21','支援業務','Support Services','生活オリエンテーション','Life Orientation','住居・銀行・行政手続きの案内','Housing, banking, government procedures',21),
 ('s22','支援業務','Support Services','定期面談・相談対応','Regular Interviews & Consultation','','',22),
 ('s23','支援業務','Support Services','行政・関係機関連携','Liaison with Authorities','入管・ハローワーク・支援団体との調整','Immigration Bureau, Hello Work, support organizations',23),
 ('s30','マーケティング','Marketing','SNS運用・発信','Social Media Management','','',30),
 ('s31','マーケティング','Marketing','コンテンツ制作','Content Production','画像・動画・記事の制作','Images, video, articles',31),
 ('s32','マーケティング','Marketing','採用マーケティング','Recruitment Marketing','求職者集客・母集団形成','Candidate attraction and pipeline building',32),
 ('s33','マーケティング','Marketing','データ分析','Data Analysis','数値管理・レポート作成','Metrics management and reporting',33),
 ('s40','バックオフィス','Back Office','労務・勤怠管理','Labor & Attendance Management','','',40),
 ('s41','バックオフィス','Back Office','経理・請求業務','Accounting & Invoicing','','',41),
 ('s42','バックオフィス','Back Office','契約書・文書管理','Contract & Document Management','','',42),
 ('s43','バックオフィス','Back Office','PC・ITツール活用','PC & IT Tools','Excel・クラウドツール等','Excel, cloud tools, etc.',43),
 ('s50','共通・マネジメント','Core & Management','問題解決・改善提案','Problem Solving & Improvement','','',50),
 ('s51','共通・マネジメント','Core & Management','後輩指導・OJT','Mentoring & OJT','','',51),
 ('s52','共通・マネジメント','Core & Management','チームマネジメント','Team Management','','',52),
 ('s53','共通・マネジメント','Core & Management','コンプライアンス理解','Compliance Awareness','個人情報・入管法・労働法の理解','Privacy, immigration law, labor law',53)
) as v(id, category, category_en, name, name_en, description, description_en, sort_order)
where not exists (select 1 from public.skill_defs);

-- licenses：閲覧は社員以上／変更は管理者以上
alter table public.licenses enable row level security;
drop policy if exists kmt_lic_select on public.licenses;
drop policy if exists kmt_lic_insert on public.licenses;
drop policy if exists kmt_lic_update on public.licenses;
drop policy if exists kmt_lic_delete on public.licenses;
create policy kmt_lic_select on public.licenses for select to authenticated using (public.my_rank() >= 1);
create policy kmt_lic_insert on public.licenses for insert to authenticated with check (public.my_rank() >= 2);
create policy kmt_lic_update on public.licenses for update to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
create policy kmt_lic_delete on public.licenses for delete to authenticated using (public.my_rank() >= 2);

-- 月報の3テーブル：閲覧は社員以上／入力・変更は管理者以上
do $$
declare t text;
begin
  foreach t in array array['case_records','monthly_reports','team_targets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists kmt_%s_select on public.%I', t, t);
    execute format('drop policy if exists kmt_%s_write  on public.%I', t, t);
    execute format('create policy kmt_%s_select on public.%I for select to authenticated using (public.my_rank() >= 1)', t, t);
    execute format('create policy kmt_%s_write on public.%I for all to authenticated using (public.my_rank() >= 2) with check (public.my_rank() >= 2)', t, t);
  end loop;
end $$;

-- SELFing のRLS：社員は自分の申告のみ読み書き可。上司評価欄はトリガーで保護
create or replace function public.my_employee_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.employees
  where lower(coalesce(email,'')) = lower(auth.jwt() ->> 'email') limit 1;
$$;
revoke all on function public.my_employee_id() from public, anon;
grant execute on function public.my_employee_id() to authenticated;

alter table public.role_master     enable row level security;
alter table public.selfing_reports enable row level security;
alter table public.selfing_roles   enable row level security;

drop policy if exists kmt_rm_select on public.role_master;
drop policy if exists kmt_rm_write  on public.role_master;
create policy kmt_rm_select on public.role_master for select to authenticated using (public.my_rank() >= 1);
create policy kmt_rm_write  on public.role_master for all to authenticated
  using (public.my_rank() >= 2) with check (public.my_rank() >= 2);

drop policy if exists kmt_sr_select on public.selfing_reports;
drop policy if exists kmt_sr_write  on public.selfing_reports;
create policy kmt_sr_select on public.selfing_reports for select to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id());
create policy kmt_sr_write on public.selfing_reports for all to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id())
  with check (public.my_rank() >= 2 or employee_id = public.my_employee_id());

drop policy if exists kmt_sl_select on public.selfing_roles;
drop policy if exists kmt_sl_write  on public.selfing_roles;
create policy kmt_sl_select on public.selfing_roles for select to authenticated
  using (public.my_rank() >= 2 or exists(
    select 1 from public.selfing_reports r
    where r.id = report_id and r.employee_id = public.my_employee_id()));
create policy kmt_sl_write on public.selfing_roles for all to authenticated
  using (public.my_rank() >= 2 or exists(
    select 1 from public.selfing_reports r
    where r.id = report_id and r.employee_id = public.my_employee_id()))
  with check (public.my_rank() >= 2 or exists(
    select 1 from public.selfing_reports r
    where r.id = report_id and r.employee_id = public.my_employee_id()));

-- 社員が上司評価の欄を書き換えられないようにする（値をold値で上書き）
create or replace function public.guard_selfing_mgr_fields()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.my_rank() < 2 then
    if tg_table_name = 'selfing_roles' then
      new.mgr_score := old.mgr_score;
      new.mgr_note  := old.mgr_note;
    elsif tg_table_name = 'selfing_reports' then
      new.mgr_comment := old.mgr_comment;
      new.reviewed_at := old.reviewed_at;
      if old.status = '上司確認済' then new.status := old.status; end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_selfing_roles_trg   on public.selfing_roles;
drop trigger if exists guard_selfing_reports_trg on public.selfing_reports;
create trigger guard_selfing_roles_trg   before update on public.selfing_roles   for each row execute function public.guard_selfing_mgr_fields();
create trigger guard_selfing_reports_trg before update on public.selfing_reports for each row execute function public.guard_selfing_mgr_fields();

-- role_skill_targets / mandala_charts のRLS
alter table public.role_skill_targets enable row level security;
alter table public.mandala_charts     enable row level security;
drop policy if exists kmt_rst_select on public.role_skill_targets;
drop policy if exists kmt_rst_write  on public.role_skill_targets;
create policy kmt_rst_select on public.role_skill_targets for select to authenticated using (public.my_rank() >= 1);
create policy kmt_rst_write  on public.role_skill_targets for all to authenticated
  using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
drop policy if exists kmt_md_select on public.mandala_charts;
drop policy if exists kmt_md_write  on public.mandala_charts;
create policy kmt_md_select on public.mandala_charts for select to authenticated
  using (scope='company' and public.my_rank()>=1
      or public.my_rank()>=2
      or employee_id = public.my_employee_id());
create policy kmt_md_write on public.mandala_charts for all to authenticated
  using (public.my_rank()>=2 or (scope='personal' and employee_id = public.my_employee_id()))
  with check (public.my_rank()>=2 or (scope='personal' and employee_id = public.my_employee_id()));

-- jd_items / jd_checks のRLS
--   項目マスタは社員以上が閲覧、管理者以上だけが編集。
--   チェックは本人と管理者だけが読み書きできる（他人の職務チェックは見えない）。
alter table public.jd_items  enable row level security;
alter table public.jd_checks enable row level security;
drop policy if exists kmt_jdi_select on public.jd_items;
drop policy if exists kmt_jdi_write  on public.jd_items;
create policy kmt_jdi_select on public.jd_items for select to authenticated using (public.my_rank() >= 1);
create policy kmt_jdi_write  on public.jd_items for all to authenticated
  using (public.my_rank() >= 2) with check (public.my_rank() >= 2);
drop policy if exists kmt_jdc_select on public.jd_checks;
drop policy if exists kmt_jdc_write  on public.jd_checks;
create policy kmt_jdc_select on public.jd_checks for select to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id());
create policy kmt_jdc_write on public.jd_checks for all to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id())
  with check (public.my_rank() >= 2 or employee_id = public.my_employee_id());

-- 担当職種は誰のものでも見えてよい（誰が何を担当しているかは社内で共有する情報）が、
-- 書き換えは本人と管理者だけ。
alter table public.jd_assignments enable row level security;
drop policy if exists kmt_jda_select on public.jd_assignments;
drop policy if exists kmt_jda_write  on public.jd_assignments;
create policy kmt_jda_select on public.jd_assignments for select to authenticated
  using (public.my_rank() >= 1);
create policy kmt_jda_write on public.jd_assignments for all to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id())
  with check (public.my_rank() >= 2 or employee_id = public.my_employee_id());

-- 実績の数字は、本人と管理者だけが読み書きできる
alter table public.jd_metrics enable row level security;
drop policy if exists kmt_jdm_select on public.jd_metrics;
drop policy if exists kmt_jdm_write  on public.jd_metrics;
create policy kmt_jdm_select on public.jd_metrics for select to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id());
create policy kmt_jdm_write on public.jd_metrics for all to authenticated
  using (public.my_rank() >= 2 or employee_id = public.my_employee_id())
  with check (public.my_rank() >= 2 or employee_id = public.my_employee_id());

-- ============================================================
-- こころの健康セルフチェック（メンタルヘルス調査）
-- KMT 人事管理システム 追加モジュール
--
-- 単体で流したいときは supabase-mental-health.sql に同じ内容が入っています。
--
-- ★ 設計の要点（法令上ここを外すと制度が成り立たない）
--   ・個人結果を見られるのは「本人」と「メンタル担当（mh_staff）」だけ。
--     管理者・全体管理でも mh_staff フラグが無ければ 1 行も見えない（RLS で強制）。
--     理由：解雇・昇進・異動に直接の権限を持つ者は、法定ストレスチェックでも
--           実施事務従事者になれない。人事権と健康情報を分離する。
--   ・管理者は mental_summary() 経由の「集計値」だけ取得できる。
--     回答者が 5 名未満の集計は個人が特定できるため、関数側で伏せる。
--   ・対応記録（面談メモ等）は別テーブルにして、本人からも見えないようにしている。
-- ============================================================

-- 4-9-1) メンタル担当フラグ ---------------------------------------
alter table public.allowed_users
  add column if not exists mh_staff boolean not null default false;

comment on column public.allowed_users.mh_staff is
  'こころの健康セルフチェックの個人結果を取り扱える担当者。人事権を持たない者に限って付与すること。';

create or replace function public.is_mh_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select mh_staff from public.allowed_users
      where lower(email) = lower(auth.jwt() ->> 'email') limit 1),
    false);
$$;
revoke all on function public.is_mh_staff() from public, anon;
grant execute on function public.is_mh_staff() to authenticated;

-- 4-9-2) 回答本体 -------------------------------------------------
create table if not exists public.mental_checks (
  id             uuid primary key default gen_random_uuid(),
  employee_id    uuid not null references public.employees(id) on delete cascade,
  period         text not null,                        -- 例: '2026年度'
  answered_on    date not null default current_date,
  consent_at     timestamptz not null default now(),   -- 本人の同意（要配慮個人情報の取得根拠）
  answers        jsonb not null default '{}'::jsonb,   -- {"q1":3, ... "q80":2}
  score_a        int,                                  -- 仕事のストレス要因 17〜68
  score_b        int,                                  -- 心身のストレス反応 29〜116
  score_c        int,                                  -- 周囲のサポート不足 9〜36
  judge          text default '',                      -- 高ストレス / やや高い / 目安内
  coping         jsonb not null default '[]'::jsonb,   -- 本人の対処法
  risk_behaviors jsonb not null default '[]'::jsonb,   -- 増えている行動
  coping_best    text default '',
  coping_plan    text default '',
  coping_hard    text default '',
  requests       jsonb not null default '[]'::jsonb,   -- 会社に求める対応
  measures       jsonb not null default '[]'::jsonb,   -- 就業上の措置の希望
  priorities     jsonb not null default '[]'::jsonb,   -- 優先してほしいこと（最大3）
  free_comment   text default '',
  good_points    text default '',
  meeting_wish   text default '希望しない',
  meeting_who    jsonb not null default '[]'::jsonb,
  meeting_style  text default '',
  meeting_lang   text default '',
  contact_time   text default '',
  urgent         boolean not null default false,       -- 「今すぐ話したい」
  oncall         text default '',                      -- 夜間・休日の緊急連絡当番
  updated_at     timestamptz not null default now(),
  unique (employee_id, period)
);
create index if not exists mental_checks_period_idx on public.mental_checks (period);

-- 4-9-3) 担当者の対応記録（本人にも見せない） ---------------------
create table if not exists public.mental_followups (
  check_id    uuid primary key references public.mental_checks(id) on delete cascade,
  status      text not null default '未対応',   -- 未対応 / 連絡済 / 面談済 / 対応中 / 完了
  staff_note  text default '',
  handled_by  text default '',
  handled_at  timestamptz,
  updated_at  timestamptz not null default now()
);

-- 4-9-4) RLS ------------------------------------------------------
alter table public.mental_checks    enable row level security;
alter table public.mental_followups enable row level security;

drop policy if exists kmt_mc_select on public.mental_checks;
drop policy if exists kmt_mc_insert on public.mental_checks;
drop policy if exists kmt_mc_update on public.mental_checks;
drop policy if exists kmt_mc_delete on public.mental_checks;

-- 本人 か メンタル担当 のみ。管理者・全体管理でもフラグが無ければ見えない
create policy kmt_mc_select on public.mental_checks for select to authenticated
  using (employee_id = public.my_employee_id() or public.is_mh_staff());
create policy kmt_mc_insert on public.mental_checks for insert to authenticated
  with check (employee_id = public.my_employee_id() or public.is_mh_staff());
create policy kmt_mc_update on public.mental_checks for update to authenticated
  using      (employee_id = public.my_employee_id() or public.is_mh_staff())
  with check (employee_id = public.my_employee_id() or public.is_mh_staff());
-- 削除は担当者のみ（本人が消すと対応中の案件が消えるため）
create policy kmt_mc_delete on public.mental_checks for delete to authenticated
  using (public.is_mh_staff());

drop policy if exists kmt_mf_all on public.mental_followups;
create policy kmt_mf_all on public.mental_followups for all to authenticated
  using (public.is_mh_staff()) with check (public.is_mh_staff());

-- 4-9-5) 集計（管理者はこれだけ見られる） -------------------------
--    回答が 5 名未満のときは個人が特定できるため中身を返さない
create or replace function public.mental_summary(p_period text)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  n int;
  res json;
begin
  if public.my_rank() < 2 and not public.is_mh_staff() then
    raise exception 'forbidden';
  end if;

  select count(*) into n from public.mental_checks where period = p_period;

  if n < 5 then
    return json_build_object('period', p_period, 'n', n, 'suppressed', true);
  end if;

  select json_build_object(
    'period',   p_period,
    'n',        n,
    'suppressed', false,
    'high',     (select count(*) from public.mental_checks where period=p_period and judge='高ストレス'),
    'mid',      (select count(*) from public.mental_checks where period=p_period and judge='やや高い'),
    'urgent',   (select count(*) from public.mental_checks where period=p_period and urgent),
    'meeting',  (select count(*) from public.mental_checks where period=p_period and meeting_wish <> '希望しない'),
    'avg_a',    (select round(avg(score_a)) from public.mental_checks where period=p_period),
    'avg_b',    (select round(avg(score_b)) from public.mental_checks where period=p_period),
    'avg_c',    (select round(avg(score_c)) from public.mental_checks where period=p_period),
    'requests', coalesce((
        select json_agg(x) from (
          select r.item as item, count(*) as cnt
            from public.mental_checks m,
                 jsonb_array_elements_text(m.requests || m.measures) as r(item)
           where m.period = p_period
           group by r.item order by count(*) desc, r.item limit 20) x), '[]'::json),
    'coping', coalesce((
        select json_agg(x) from (
          select c.item as item, count(*) as cnt
            from public.mental_checks m,
                 jsonb_array_elements_text(m.coping) as c(item)
           where m.period = p_period
           group by c.item order by count(*) desc, c.item limit 20) x), '[]'::json)
  ) into res;
  return res;
end $$;
revoke all on function public.mental_summary(text) from public, anon;
grant execute on function public.mental_summary(text) to authenticated;

-- 住所変更履歴：従業員本体と同じ（管理者以上は全員分、社員は自分の分だけ閲覧。書き込みは管理者以上）
alter table public.employee_address_history enable row level security;
drop policy if exists kmt_addr_select on public.employee_address_history;
drop policy if exists kmt_addr_write  on public.employee_address_history;
create policy kmt_addr_select on public.employee_address_history for select to authenticated
  using (public.my_rank() >= 2 or (public.my_rank() = 1 and employee_id = public.my_employee_id()));
create policy kmt_addr_write on public.employee_address_history for all to authenticated
  using (public.my_rank() >= 2) with check (public.my_rank() >= 2);

-- 5) 最初の全体管理者 -----------------------------------------------
--    ここで登録するのはメールアドレスと権限だけです。
--    パスワードは本人がログイン画面の「新規登録（初回のみ）」で設定します。
do $$
begin
  if exists (select 1 from public.allowed_users where lower(email) = 'nisa@k-m-t.jp') then
    update public.allowed_users
       set role = '全体管理', display_name = coalesce(nullif(display_name,''), 'Nisa')
     where lower(email) = 'nisa@k-m-t.jp';
  else
    insert into public.allowed_users (email, display_name, role)
    values ('nisa@k-m-t.jp', 'Nisa', '全体管理');
  end if;
end $$;

select email, display_name, role from public.allowed_users order by role, email;
