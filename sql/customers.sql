--a)
-- past delivery ratings
CREATE OR REPLACE FUNCTION past_delivery_ratings(customers_uid INTEGER)
 RETURNS TABLE (
     order_id INTEGER,
     order_time TIMESTAMP,
     delivery_ratings INTEGER,
     rider_name VARCHAR
 ) AS $$
     SELECT D.order_id, FO.date_time, D.delivery_rating, U.name
     FROM Delivery D join FoodOrder FO on D.order_id = FO.order_id
     join Users U on D.rider_id = U.uid
     WHERE FO.uid = customers_uid
     AND D.delivery_rating IS NOT NULL;
 $$ LANGUAGE SQL;

 CREATE OR REPLACE FUNCTION start_time(deliveryid INTEGER)
 RETURNS TIMESTAMP AS $$
     SELECT D.delivery_start_time
     FROM Delivery D
     WHERE D.delivery_id = deliveryid;
 $$ LANGUAGE SQL;

 --b)
 --past food reviews
 CREATE OR REPLACE FUNCTION past_food_reviews(customers_uid INTEGER)
 RETURNS TABLE (
     order_id INTEGER,
     order_time TIMESTAMP,
     restaurant_name VARCHAR,
     food_review VARCHAR
 ) AS $$
     SELECT D.order_id, FO.date_time, R.rname, D.food_review
     FROM Delivery D join FoodOrder FO on D.order_id = FO.order_id join Restaurants R on R.rid = FO.rid
     WHERE FO.uid = customers_uid
     AND D.food_review IS NOT NULL;
 $$ LANGUAGE SQL;


 --c)
 --List of restaurants
  CREATE OR REPLACE FUNCTION list_of_restaurant()
 RETURNS TABLE (
     restaurant_id INTEGER,
     restaurant_name VARCHAR,
     min_order_price DECIMAL
 ) AS $$
     SELECT R.rid, R.rname, R.min_order_price
     FROM Restaurants R
 $$ LANGUAGE SQL;


 --d)
 --List of available food items
 CREATE OR REPLACE FUNCTION list_of_fooditems(restaurant_id INTEGER)
 RETURNS TABLE (
     food_id INTEGER,
     food_name VARCHAR,
     food_price DECIMAL,
     cuisine_type VARCHAR,
     overall_rating DECIMAL,
     availability_status BOOLEAN,
     is_deleted BOOLEAN,
        quantity INTEGER
 ) AS $$
     SELECT FI.food_id, FI.food_name, S.price, FI.cuisine_type, FI.overall_rating, FI.availability_status, FI.is_deleted, FI.restaurant_quantity
     FROM FoodItem FI join Sells S on FI.food_id = S.food_id
     WHERE FI.rid = restaurant_id
 $$ LANGUAGE SQL;

 --trigger when choosen quantity > available quantity
 CREATE OR REPLACE FUNCTION notify_user() RETURNS TRIGGER AS $$
 BEGIN
    IF  NEW.ordered_count > OLD.restaurant_quantity THEN
        RAISE EXCEPTION 'ordered quantity more than available quantity';
    END IF;
    RETURN NEW;
 END;
 $$ LANGUAGE PLPGSQL;
 DROP TRIGGER IF EXISTS notify_user_trigger ON FoodItem CASCADE;
 CREATE TRIGGER notify_user_trigger
  BEFORE UPDATE OF ordered_count
  ON FoodItem
  FOR EACH ROW
  EXECUTE FUNCTION notify_user();

    --trigger when choosen total order cost < min order
 CREATE OR REPLACE FUNCTION notify_minorder_not_met() RETURNS TRIGGER AS $$
 DECLARE
    minorderprice DECIMAL;
 BEGIN
    SELECT R.min_order_price INTO minorderprice
    FROM  Restaurants R
    WHERE R.rid = NEW.rid;
    IF  NEW.order_cost < minorderprice THEN
        RAISE EXCEPTION 'ordered cost is less than minimum order cost of %', minorderprice;
    END IF;
    RETURN NEW;
 END;
 $$ LANGUAGE PLPGSQL;
 DROP TRIGGER IF EXISTS notify_minorder_not_met ON FoodOrder CASCADE;
 CREATE TRIGGER notify_minorder_not_met
  BEFORE INSERT
  ON FoodOrder
  FOR EACH ROW
  EXECUTE FUNCTION notify_minorder_not_met();

  --trigger to update isdelivering for the particular rider
 CREATE OR REPLACE FUNCTION update_rider_isdelivering() RETURNS TRIGGER AS $$
 BEGIN
    UPDATE Riders
    SET is_delivering = TRUE
    WHERE rider_id = NEW.rider_id;
    RETURN NEW;
 END;
 $$ LANGUAGE PLPGSQL;
 DROP TRIGGER IF EXISTS update_rider_isdelivering_trigger ON Delivery CASCADE;
 CREATE TRIGGER update_rider_isdelivering_trigger
  AFTER INSERT
  ON Delivery
  FOR EACH ROW
  EXECUTE FUNCTION update_rider_isdelivering();

 --trigger to check if there are available riders
 CREATE OR REPLACE FUNCTION check_available_riders() RETURNS TRIGGER AS $$
 BEGIN
    IF NEW.rider_id IS NULL THEN
      RAISE EXCEPTION 'There are no available riders right now';
    END IF;
    RETURN NEW;
 END;
 $$ LANGUAGE PLPGSQL;
 DROP TRIGGER IF EXISTS check_available_riders ON Delivery CASCADE;
 CREATE TRIGGER check_available_riders
  BEFORE INSERT
  ON Delivery
  FOR EACH ROW
  EXECUTE FUNCTION check_available_riders();

--e (i) run this function first
 --function to activate riders that are working NOW
CREATE OR REPLACE FUNCTION activate_riders()
RETURNS VOID AS $$
BEGIN
  UPDATE Riders R
  SET working = TRUE
  WHERE R.rider_id IN (SELECT WWS.rider_id
                      FROM WeeklyWorkSchedule WWS
                      WHERE WWS.start_hour = (SELECT EXTRACT(HOUR FROM current_timestamp))
                      AND WWS.day%7 = (SELECT EXTRACT(DOW FROM current_timestamp))
                      AND WWS.week =  (SELECT EXTRACT('day' from date_trunc('week', current_timestamp)
                                                      - date_trunc('week', date_trunc('month',  current_timestamp))) / 7 + 1 )
                      AND WWS.month = (SELECT EXTRACT(MONTH FROM current_timestamp))
                      AND WWS.year = (SELECT EXTRACT(YEAR FROM current_timestamp))
                      );
   UPDATE Riders R
   SET working = FALSE
   WHERE R.rider_id NOT IN (SELECT WWS.rider_id
                      FROM WeeklyWorkSchedule WWS
                      WHERE WWS.start_hour = (SELECT EXTRACT(HOUR FROM current_timestamp))
                      AND WWS.day%7 = (SELECT EXTRACT(DOW FROM current_timestamp))
                      AND WWS.week =  (SELECT EXTRACT('day' from date_trunc('week', current_timestamp)
                                                      - date_trunc('week', date_trunc('month',  current_timestamp))) / 7 + 1 )
                      AND WWS.month = (SELECT EXTRACT(MONTH FROM current_timestamp))
                      AND WWS.year = (SELECT EXTRACT(YEAR FROM current_timestamp))
                      );
END
 $$ LANGUAGE PLPGSQL;



--e (ii)
 --create new foodorder, create new delivery, update order count
 --returns orderid and deliveryid as a tuple
 --currentorder is a 2d array which consist of the { {foodid,quantity}, {foodid2,quantity} }

CREATE OR REPLACE FUNCTION update_order_count(currentorder INTEGER[][],
                                              customer_uid INTEGER,
                                              restaurant_id INTEGER,
                                              have_credit BOOLEAN,
                                              total_order_cost DECIMAL,
                                              delivery_location VARCHAR(100),
                                              delivery_fee DECIMAL)
 RETURNS VOID AS $$
 DECLARE
    orderid INTEGER;
    deliveryid INTEGER;
    orderedcount INTEGER;
    foodquantity INTEGER;
    item INTEGER[];
 BEGIN
      INSERT INTO FoodOrder(uid, rid, have_credit_card, order_cost, date_time, completion_status)
      VALUES (customer_uid, restaurant_id, have_credit, total_order_cost, current_timestamp, FALSE)
      RETURNING order_id into orderid;

      INSERT INTO Delivery(order_id, rider_id, delivery_cost, location, ongoing)
      VALUES (orderid,
              (SELECT CASE WHEN (SELECT R.rider_id FROM Riders R WHERE R.working = TRUE AND R.is_delivering = FALSE ORDER BY random() LIMIT 1) IS NOT NULL
                      THEN (SELECT R.rider_id FROM Riders R WHERE R.working = TRUE AND R.is_delivering = FALSE  ORDER BY random() LIMIT 1)
                      ELSE (SELECT R.rider_id FROM Riders R WHERE R.working = TRUE ORDER BY random() LIMIT 1)
                      END),
              delivery_fee,
              delivery_location,
              TRUE) --flat fee of 5 for delivery cost
      RETURNING delivery_id into deliveryid;

       FOREACH item SLICE 1 IN ARRAY currentorder LOOP
          SELECT ordered_count into orderedcount FROM FoodItem WHERE food_id = item[1];
          SELECT restaurant_quantity into foodquantity FROM FoodItem WHERE food_id = item[1];
          UPDATE FoodItem FI
          SET ordered_count = ordered_count + item[2]
          WHERE item[1] = FI.food_id;
          IF orderedcount + item[2] = foodquantity THEN
            UPDATE FoodItem FI
            SET availability_status = false
            WHERE item[1] = FI.food_id;
          END IF;
          INSERT INTO OrdersContain(order_id,food_id,item_quantity)
          VALUES (orderid,item[1],item[2]);
       END loop;
       UPDATE Customers C
       SET points = points + CAST(floor(total_order_cost/5) AS INTEGER) --Gain 1 reward point every $5 spent
       WHERE C.uid = customer_uid;
 END
 $$ LANGUAGE PLPGSQL;

 --e(iii)
 -- get delivery_id and order_id
 CREATE OR REPLACE FUNCTION get_ids(customer_uid INTEGER, restaurant_id INTEGER, total_order_cost DECIMAL)
 RETURNS TABLE (
    orderid INTEGER,
    deliveryid INTEGER
    ) AS $$
        SELECT D.order_id, D.delivery_id
        FROM Delivery D join FoodOrder FO on FO.order_id = D.order_id
        WHERE FO.uid = customer_uid
        AND FO.rid = restaurant_id
        AND FO.order_cost = total_order_cost
        ORDER BY D.delivery_id DESC
        LIMIT 1;
      $$ LANGUAGE SQL;

 -- 5 most recent Location
 CREATE OR REPLACE FUNCTION most_recent_location(input_customer_id INTEGER)
 RETURNS TABLE (
  recentlocations VARCHAR
 ) AS $$
     SELECT D.location
     FROM Delivery D join FoodOrder FO on D.order_id = FO.order_id
     WHERE FO.uid = input_customer_id
     ORDER BY D.delivery_end_time desc
     LIMIT 5;
 $$ LANGUAGE SQL;

  -- 5 most recent Location
 CREATE OR REPLACE FUNCTION most_recent_location(input_customer_id INTEGER)
 RETURNS TABLE (
  recentlocations VARCHAR
 ) AS $$
     SELECT D.location
     FROM Delivery D join FoodOrder FO on D.order_id = FO.order_id
     WHERE FO.uid = input_customer_id
     ORDER BY D.delivery_end_time desc
     LIMIT 5;
 $$ LANGUAGE SQL;

---- apply delivery promo IF HAVE REWARD POINTS, USE TO OFFSET (USE REWARD BUTTON)
CREATE OR REPLACE FUNCTION apply_delivery_promo(input_customer_id INTEGER, delivery_cost INTEGER)
RETURNS VOID AS $$
declare 
    points_check INTEGER;
begin
    SELECT points
    FROM Customers C 
    WHERE C.uid = input_customer_id
    INTO points_check;

    IF (points_check = 0) THEN 
        RAISE EXCEPTION 'You have no points to be deducted';
    END IF;
    IF (points_check >= delivery_cost) THEN
        UPDATE Customers
        SET points = (points - delivery_cost)
        WHERE uid = input_customer_id;
    ELSIF (points_check < delivery_cost) THEN 
        UPDATE Customers
        SET points = 0
        WHERE uid = input_customer_id;
    END IF;
end
$$ LANGUAGE PLPGSQL;


 --f)
 -- reward balance
 CREATE OR REPLACE FUNCTION reward_balance(customer_id INTEGER)
 RETURNS INTEGER AS $$
     SELECT C.points
     FROM Customers C
     WHERE C.uid = customer_id;
 $$ LANGUAGE SQL;

  --g)
  --delivery page
  -- rider name/id
 CREATE OR REPLACE FUNCTION rider_name(deliveryid INTEGER)
 RETURNS VARCHAR AS $$
     SELECT U.name
     FROM Delivery D join Users U on D.rider_id = U.uid
     WHERE D.delivery_id = deliveryid;
 $$ LANGUAGE SQL;

 --delivery id

 --delivery time
 CREATE OR REPLACE FUNCTION delivery_timings(deliveryid INTEGER)
  RETURNS TABLE (
  ordertime TIMESTAMP,
  riderdeparturetime TIMESTAMP,
  ridercollectedtime TIMESTAMP,
  deliverystarttime TIMESTAMP
 ) AS $$
     SELECT FO.date_time, D.departure_time, D.collected_time, D.delivery_start_time
     FROM Delivery D join FoodOrder FO on FO.order_id = D.order_id
     WHERE D.delivery_id = deliveryid;
 $$ LANGUAGE SQL;

 --location
 CREATE OR REPLACE FUNCTION location(deliveryid INTEGER)
 RETURNS VARCHAR AS $$
     SELECT D.location
     FROM Delivery D
     WHERE D.delivery_id = deliveryid;
 $$ LANGUAGE SQL;

 --rider rating
 CREATE OR REPLACE FUNCTION rider_rating(deliveryid INTEGER)
 RETURNS DECIMAL AS $$
     SELECT round(R.rating, 3)
     FROM Delivery D join Riders R on D.rider_id = R.rider_id
     WHERE D.delivery_id = deliveryid;
 $$ LANGUAGE SQL;


 --i)
 --delivery end time
 CREATE OR REPLACE FUNCTION delivery_endtime(deliveryid INTEGER)
 RETURNS TIMESTAMP AS $$
     SELECT D.delivery_end_time
     FROM Delivery D
     WHERE D.delivery_id = deliveryid;
 $$ LANGUAGE SQL;

 --review food update
 CREATE OR REPLACE FUNCTION food_review_update(foodreview VARCHAR, deliveryid INTEGER)
 RETURNS VOID AS $$
    UPDATE Delivery
    SET food_review = foodreview
    WHERE delivery_id = deliveryid;
 $$ LANGUAGE SQL;

 --trigger rating update
 CREATE OR REPLACE FUNCTION update_rider_ratings() RETURNS TRIGGER AS $$
 BEGIN
    UPDATE Riders
    set rating = (SELECT (sum(D.delivery_rating)::DECIMAL/count(D.delivery_rating))::DECIMAL as average_ratings FROM Delivery D WHERE D.rider_id = OLD.rider_id GROUP BY D.rider_id)
    WHERE rider_id = OLD.rider_id;
    RETURN NEW;
 END;
 $$ LANGUAGE PLPGSQL;

 DROP TRIGGER IF EXISTS update_rating_trigger ON Delivery CASCADE;
 CREATE TRIGGER update_rating_trigger
    AFTER UPDATE OF delivery_rating ON Delivery
    FOR EACH ROW
    EXECUTE FUNCTION update_rider_ratings();

--Update delivery rating which triggers rider rating update
  CREATE OR REPLACE FUNCTION update_delivery_rating(deliveryid INTEGER, deliveryrating INTEGER)
  RETURNS VOID AS $$
      UPDATE Delivery
      SET delivery_rating = deliveryrating
      WHERE delivery_id = deliveryid;
  $$ LANGUAGE SQL;
