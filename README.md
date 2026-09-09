# README

A small Rails API exploring safe and idempotent financial operations, including concurrent withdrawals, database transactions and row-level locking.

Read DESIGN_DOCUMENT.md

Use bundle config set --local path 'vendor/bundle' to configure the project for local installation of gems

Execute bundle install

Migrate db

rails db:migrate

Use "bundle exec rails test" to execute the tests