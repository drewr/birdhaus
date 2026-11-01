-- Which product an order is for, now that there is more than one. Earlier
-- orders were all Bluebird Houses.
alter table orders add column product text not null default 'bluebird-house';
