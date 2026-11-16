(ns zouch.jepsen
  "Jepsen tests for Zouch.

  The suite is intentionally single-node: Zouch has no cluster membership, so
  the tests focus on the failure modes that matter for a local document store:
  process crashes, long pauses, network isolation and a full data filesystem.

  Usage:
    lein run smoke       # no faults
    lein run kill        # repeated SIGKILL/restart
    lein run pause       # repeated SIGSTOP/SIGCONT
    lein run partition   # block/unblock the HTTP port
    lein run disk        # fill a small tmpfs, free it, then crash/restart
    lein run attachments # attachment writes/reads under all local faults
    lein run pull        # target-initiated pull replication under faults
    lein run continuous  # _replicator continuous replication under faults
    lein run multipeer   # one source fanning out to two target peers"
  (:require [cheshire.core :as json]
            [clj-http.client :as http]
            [clojure.string :as str]
            [jepsen.core :as jepsen]
            [jepsen.control :as control]
            [jepsen.control.util :as cu]
            [jepsen.client :as client]
            [jepsen.checker :as checker]
            [jepsen.db :as db]
            [jepsen.generator :as gen]
            [jepsen.independent :as independent]
            [jepsen.nemesis :as nemesis]
            [jepsen.tests :as tests]
            [jepsen.tests.linearizable-register :as lreg])
  (:import (java.util Arrays Base64)))

(def node "localhost")
(def repo (or (System/getenv "ZOUCH_REPO") "/home/ubuntu/code/zouch"))
(def port (Integer/parseInt (or (System/getenv "JEPSEN_PORT") "5985")))
(def target-port (Integer/parseInt (or (System/getenv "JEPSEN_TARGET_PORT")
                                        (str (+ port 6)))))
(def target2-port (Integer/parseInt (or (System/getenv "JEPSEN_TARGET2_PORT")
                                         (str (+ port 7)))))
(def db-name "jepsen_zouch")
(def data-dir "/tmp/zouch-jepsen")
(def pid-file "/tmp/zouch-jepsen.pid")
(def log-file "/tmp/zouch-jepsen.log")
(def source-data-dir "/tmp/zouch-jepsen-source")
(def source-pid-file "/tmp/zouch-jepsen-source.pid")
(def source-log-file "/tmp/zouch-jepsen-source.log")
(def target-data-dir "/tmp/zouch-jepsen-target")
(def target-pid-file "/tmp/zouch-jepsen-target.pid")
(def target-log-file "/tmp/zouch-jepsen-target.log")
(def target2-data-dir "/tmp/zouch-jepsen-target2")
(def target2-pid-file "/tmp/zouch-jepsen-target2.pid")
(def target2-log-file "/tmp/zouch-jepsen-target2.log")
(def disk-mount "/mnt/zouch-jepsen")

(defn base-url [p]
  (str "http://127.0.0.1:" p))

(defn doc-url [p k]
  (str (base-url p) "/" db-name "/" k))

(defn response [r]
  {:status (:status r) :body (:body r)})

(def http-opts
  {:throw-exceptions false
   :as :json
   :connection-timeout 1000
   :socket-timeout 1500})

(defn safe-http [f]
  (try
    (f)
    (catch Exception e
      {:status nil
       :error (str (class e) ": " (or (.getMessage e) "no-message"))})))

(defrecord ZouchClient [port]
  client/Client
  (open! [this _test _node] this)
  (close! [_this _test])

  (setup! [_this _test]
    (http/delete (str (base-url port) "/" db-name)
                 {:throw-exceptions false :as :json})
    (let [r (http/put (str (base-url port) "/" db-name)
                      {:throw-exceptions false :as :json})]
      (when-not (= 201 (:status r))
        (throw (ex-info "cannot create jepsen database" (response r))))))

  (teardown! [_this _test]
    (http/delete (str (base-url port) "/" db-name)
                 {:throw-exceptions false :as :json}))

  (invoke! [_this _test op]
    (let [[k v] (:value op)]
      (case (:f op)
        :read
        (let [r (safe-http #(http/get (doc-url port k) http-opts))]
          (cond
            (= 200 (:status r))
            (assoc op :type :ok :value (independent/tuple k (get (:body r) :value)))

            (= 404 (:status r))
            (assoc op :type :ok :value (independent/tuple k nil))

            (nil? (:status r))
            (assoc op :type :info :error (:error r))

            :else
            (assoc op :type :info :error (str "read-http-" (:status r)))))

        :write
        (loop [attempt 0]
          (let [current (safe-http #(http/get (doc-url port k) http-opts))]
            (cond
              (nil? (:status current))
              (assoc op :type :info :error (:error current))

              (not (#{200 404} (:status current)))
              (assoc op :type :info :error (str "write-get-" (:status current)))

              :else
              (let [rev (when (= 200 (:status current))
                          (get-in current [:body :_rev]))
                    body (cond-> {"value" v} rev (assoc "_rev" rev))
                    r (safe-http #(http/put (doc-url port k)
                                            (assoc http-opts
                                                   :content-type :json
                                                   :body (json/generate-string body))))]
                (cond
                  (= 201 (:status r))
                  (assoc op :type :ok :value (independent/tuple k v))

                  (= 409 (:status r))
                  (if (< attempt 8)
                    (recur (inc attempt))
                    (assoc op :type :fail :error :conflict))

                  (nil? (:status r))
                  (assoc op :type :info :error (:error r))

                  :else
                  (assoc op :type :info :error (str "write-http-" (:status r))))))))

        :cas
        (let [[old new] v
              current (safe-http #(http/get (doc-url port k) http-opts))]
          (cond
            (nil? (:status current))
            (assoc op :type :info :error (:error current))

            (not (#{200 404} (:status current)))
            (assoc op :type :info :error (str "cas-get-" (:status current)))

            :else
            (let [cur (when (= 200 (:status current))
                        (get-in current [:body :value]))
                  rev (when (= 200 (:status current))
                        (get-in current [:body :_rev]))]
              (if (not= cur old)
                (assoc op :type :fail :error :cas-mismatch)
                (loop [attempt 0]
                  (let [body (cond-> {"value" new} rev (assoc "_rev" rev))
                        r (safe-http #(http/put (doc-url port k)
                                                (assoc http-opts
                                                       :content-type :json
                                                       :body (json/generate-string body))))]
                    (cond
                      (= 201 (:status r))
                      (assoc op :type :ok :value (independent/tuple k [old new]))

                      (= 409 (:status r))
                      (if (< attempt 8)
                        (recur (inc attempt))
                        (assoc op :type :fail :error :conflict))

                      (nil? (:status r))
                      (assoc op :type :info :error (:error r))

                      :else
                      (assoc op :type :info :error (str "cas-http-" (:status r))))))))))

        (assoc op :type :fail :error :unsupported-op)))))

(defn wait-health!
  [p]
  (control/on node
    (control/exec :bash "-lc"
                  (str "for i in $(seq 1 100); do "
                       "curl -fsS " (base-url p) "/ >/dev/null && exit 0; "
                       "sleep 0.1; done; exit 1"))))

(defn mount-disk! []
  (control/on node
    (control/su
      (control/exec :mkdir :-p disk-mount)
      (try
        (control/exec :umount disk-mount)
        (catch Exception _ nil))
      (control/exec :mount :-t "tmpfs" :-o "size=64M" "tmpfs" disk-mount)
      (control/exec :chown "ubuntu:ubuntu" disk-mount))))

(defn umount-disk! []
  (control/on node
    (control/su
      (try
        (control/exec :umount disk-mount)
        (catch Exception _ nil)))))

(defn start-server!
  [{:keys [port data-dir pid-file log-file]}]
  (control/on node
    (control/exec :mkdir :-p data-dir)
    (control/exec :rm :-f pid-file)
    (cu/start-daemon! {:chdir repo
                       :logfile log-file
                       :pidfile pid-file
                       :match-executable? true}
                      (str repo "/zig-out/bin/zouch")
                      "serve" data-dir (str port)))
  (wait-health! port))

(defn stop-server!
  [{:keys [pid-file]}]
  (control/on node
    (try
      (cu/stop-daemon! nil pid-file 9)
      (catch Exception _ nil))
    (try
      (control/exec :bash "-lc"
                    (str "if [ -f " pid-file " ]; then kill -9 $(cat " pid-file
                         ") 2>/dev/null || true; fi"))
      (catch Exception _ nil))))

(defn pause-server! []
  (control/on node
    (try
      (control/exec :bash "-lc" "pkill -STOP -x zouch 2>/dev/null || true")
      (catch Exception _ nil))))

(defn resume-server! []
  (control/on node
    (try
      (control/exec :bash "-lc" "pkill -CONT -x zouch 2>/dev/null || true")
      (catch Exception _ nil))))

(defn fill-disk!
  [{:keys [data-dir]}]
  (control/on node
    (control/exec :bash "-lc"
                  (str "rm -f " data-dir "/fill.*; "
                       "for i in $(seq 1 100); do "
                       "fallocate -l 1M " data-dir "/fill.$i 2>/dev/null || break; "
                       "done"))))

(defn free-disk!
  [{:keys [data-dir]}]
  (control/on node
    (control/exec :bash "-lc" (str "rm -f " data-dir "/fill.*"))))

(defn partition!
  [p]
  (control/on node
    (control/su
      (control/exec :iptables :-I "INPUT" "1" :-p "tcp"
                    :--dport (str p) :-j "DROP")
      (control/exec :iptables :-I "OUTPUT" "1" :-p "tcp"
                    :--dport (str p) :-j "DROP"))))

(defn heal!
  [p]
  (control/on node
    (control/su
      (try
        (control/exec :iptables :-D "INPUT" :-p "tcp"
                      :--dport (str p) :-j "DROP")
        (catch Exception _ nil))
      (try
        (control/exec :iptables :-D "OUTPUT" :-p "tcp"
                      :--dport (str p) :-j "DROP")
        (catch Exception _ nil)))))

(defrecord ZouchDB [port data-dir pid-file log-file disk?]
  db/DB
  (setup! [this _test node]
    (stop-server! this)
    (when disk?
      (mount-disk!))
    (when-not disk?
      (control/on node
        (control/exec :rm :-rf data-dir)))
    (control/on node
      (control/exec :mkdir :-p data-dir))
    (start-server! this))

  (teardown! [this _test _node]
    (stop-server! this)
    (when disk?
      (umount-disk!))
    (control/on node
      (control/exec :rm :-rf data-dir))))

(defrecord ZouchNemesis [db]
  nemesis/Nemesis
  (setup! [this _test] this)
  (teardown! [this _test]
    (heal! port)
    this)

  (invoke! [this test op]
    (let [f (:f op)]
      (try
        (case f
          :kill (do (stop-server! db)
                    (assoc op :type :info :value :killed))
          :start (do (start-server! db)
                     (assoc op :type :info :value :started))
          :pause (do (pause-server!)
                     (assoc op :type :info :value :paused))
          :resume (do (resume-server!)
                      (assoc op :type :info :value :resumed))
          :fill (do (fill-disk! db)
                    (assoc op :type :info :value :filled))
          :free (do (free-disk! db)
                    (assoc op :type :info :value :freed))
          :partition (do (partition! port)
                         (assoc op :type :info :value :partitioned))
          :heal (do (heal! port)
                    (assoc op :type :info :value :healed))
          (assoc op :type :info :value :unknown))
        (catch Exception e
          (assoc op :type :info :error (or (.getMessage e) (str (class e)))))))))

(defn ensure-db!
  [p]
  (http/put (str (base-url p) "/" db-name)
            {:throw-exceptions false :as :json}))

(def replication-stats
  (atom {:attempts 0 :ok 0 :fail 0 :last-error nil}))

(defn start-replicator!
  [source-port target-port]
  (reset! replication-stats {:attempts 0 :ok 0 :fail 0 :last-error nil})
  (let [running (atom true)]
    (future
      (while @running
        (let [ready? (try
                       (= 200 (:status (http/get (str (base-url source-port) "/" db-name)
                                                 (assoc http-opts :socket-timeout 500))))
                       (catch Exception _ false))]
          (if-not ready?
            (Thread/sleep 100)
            (do
              (swap! replication-stats update :attempts inc)
              (try
                (let [r (http/post (str (base-url source-port) "/_replicate")
                                   (assoc http-opts
                                          :content-type :json
                                          :body (json/generate-string
                                                  {"source" db-name
                                                   "target" (str (base-url target-port) "/" db-name)})))]
                  (if (= 200 (:status r))
                    (swap! replication-stats update :ok inc)
                    (swap! replication-stats
                           (fn [s]
                             (-> s
                                 (update :fail inc)
                                 (assoc :last-error (str "http-" (:status r))))))))
                (catch Exception e
                  (swap! replication-stats
                         (fn [s]
                           (-> s
                               (update :fail inc)
                               (assoc :last-error (or (.getMessage e) (str (class e)))))))))
              (Thread/sleep 250))))))
    (fn [] (reset! running false))))

(defrecord ReplicationDB [source target stop-atom]
  db/DB
  (setup! [this _test node]
    (db/setup! source _test node)
    (db/setup! target _test node)
    (ensure-db! (:port target))
    (reset! stop-atom
            (start-replicator! (:port source) (:port target))))

  (teardown! [this _test node]
    (when-let [stop @stop-atom]
      (stop)
      (reset! stop-atom nil))
    (db/teardown! source _test node)
    (db/teardown! target _test node)))

(defrecord ReplicationNemesis [source target]
  nemesis/Nemesis
  (setup! [this _test] this)
  (teardown! [this _test]
    (heal! (:port target))
    this)

  (invoke! [this _test op]
    (try
      (case (:f op)
        :kill-target (do (stop-server! target)
                         (assoc op :type :info :value :target-killed))
        :start-target (do (start-server! target)
                          (assoc op :type :info :value :target-started))
        :kill-source (do (stop-server! source)
                         (assoc op :type :info :value :source-killed))
        :start-source (do (start-server! source)
                          (assoc op :type :info :value :source-started))
        :partition (do (partition! (:port target))
                       (assoc op :type :info :value :partitioned))
        :heal (do (heal! (:port target))
                  (assoc op :type :info :value :healed))
        (assoc op :type :info :value :unknown))
      (catch Exception e
        (assoc op :type :info :error (or (.getMessage e) (str (class e))))))))

(defn doc-state
  [p k]
  (let [r (safe-http #(http/get (doc-url p k) http-opts))]
    (if (= 200 (:status r))
      {:rev (get-in r [:body :_rev])
       :value (get-in r [:body :value])}
      {:status (:status r) :error (:error r)})))

(defrecord ConvergenceChecker [source-port target-port]
  checker/Checker
  (check [_this _test history _opts]
    (let [ks (->> history
                  (keep #(when (vector? (:value %)) (first (:value %))))
                  distinct
                  vec)
          deadline (+ (System/currentTimeMillis) 15000)]
      (loop []
        (let [pairs (map (fn [k] [k (doc-state source-port k) (doc-state target-port k)]) ks)
              diverged (remove (fn [[_ s t]] (and (= (:rev s) (:rev t))
                                                  (= (:value s) (:value t))))
                               pairs)]
          (if (empty? diverged)
            {:valid? true
             :keys (count ks)
             :replication @replication-stats}
            (if (< (System/currentTimeMillis) deadline)
              (do (Thread/sleep 250) (recur))
              {:valid? false
               :keys (count ks)
               :diverged (take 10 diverged)
               :replication @replication-stats})))))))

(defn replication-checker
  [history-checker source-port target-port]
  (checker/compose
    {:history history-checker
     :convergence (->ConvergenceChecker source-port target-port)}))

;; ---------------------------------------------------------------------------
;; Attachment workload
;; ---------------------------------------------------------------------------

(def attachment-sizes [0 1 7 64 256 1024 2048])
(def attachment-content-types
  ["application/octet-stream" "text/plain" "application/json"])

(defn b64-encode
  ^String [^bytes data]
  (.encodeToString (Base64/getEncoder) data))

(defn b64-decode
  ^bytes [^String s]
  (.decode (Base64/getDecoder) s))

(defn bytes-equal?
  [^bytes a ^bytes b]
  (and (some? a) (some? b) (Arrays/equals a b)))

(defn bytes-len
  [^bytes b]
  (if b (alength b) 0))

(defn sha256-hex
  [^bytes data]
  (let [d (java.security.MessageDigest/getInstance "SHA-256")]
    (apply str (map #(format "%02x" %) (.digest d data)))))

(defn attachment-spec
  "Deterministic payload descriptor for a document index.  Keeping only the
  descriptor in the Jepsen history avoids storing megabytes of attachment data
  in history.edn."
  [i]
  {:len (nth attachment-sizes (mod i (count attachment-sizes)))
   :seed (mod (* (inc i) 7919) 65536)
   :ct (nth attachment-content-types (mod i (count attachment-content-types)))})

(defn attachment-bytes
  ^bytes [{:keys [seed len]}]
  (let [arr (byte-array (int len))]
    (dotimes [i len]
      (aset-byte arr i (unchecked-byte (bit-and (+ (* i 31) seed 17) 0xFF))))
    arr))

(defrecord AttachmentClient [port]
  client/Client
  (open! [this _test _node] this)
  (close! [_this _test])

  (setup! [_this _test]
    (http/delete (str (base-url port) "/" db-name)
                 {:throw-exceptions false :as :json})
    (let [r (http/put (str (base-url port) "/" db-name)
                      {:throw-exceptions false :as :json})]
      (when-not (= 201 (:status r))
        (throw (ex-info "cannot create jepsen database" (response r))))))

  (teardown! [_this _test]
    (http/delete (str (base-url port) "/" db-name)
                 {:throw-exceptions false :as :json}))

  (invoke! [_this _test op]
    (let [[k spec] (:value op)]
      (case (:f op)
        :attach
        ;; Unique ids are used by the generator, but a retry after a lost
        ;; response must still CAS on the current revision.  The payload is a
        ;; pure function of the descriptor, so a retry cannot change bytes.
        (loop [attempt 0]
          (let [current (safe-http #(http/get (doc-url port k) http-opts))]
            (cond
              (nil? (:status current))
              (assoc op :type :info :error (:error current))

              (not (#{200 404} (:status current)))
              (assoc op :type :info :error (str "attach-get-" (:status current)))

              :else
              (let [rev (when (= 200 (:status current))
                          (get-in current [:body :_rev]))
                    data (b64-encode (attachment-bytes spec))
                    body (cond-> {"i" k
                                  "_attachments"
                                  {"blob" {"content_type" (:ct spec)
                                           "data" data}}}
                           rev (assoc "_rev" rev))
                    r (safe-http #(http/put (doc-url port k)
                                            (assoc http-opts
                                                   :content-type :json
                                                   :body (json/generate-string body))))]
                (cond
                  (= 201 (:status r))
                  (assoc op :type :ok :value (independent/tuple k spec))

                  (= 409 (:status r))
                  (if (< attempt 8)
                    (recur (inc attempt))
                    (assoc op :type :fail :error :conflict))

                  (nil? (:status r))
                  (assoc op :type :info :error (:error r))

                  (= 507 (:status r))
                  (assoc op :type :info :error :storage-full)

                  :else
                  (assoc op :type :info :error (str "attach-http-" (:status r))))))))

        :read-att
        (let [expected (attachment-bytes spec)
              r (safe-http #(http/get (str (doc-url port k) "/blob")
                                      (assoc http-opts :as :byte-array)))]
          (cond
            (= 200 (:status r))
            (if (bytes-equal? expected (:body r))
              (assoc op :type :ok :value (independent/tuple k :match))
              (assoc op :type :fail :error :byte-mismatch
                     :value (independent/tuple
                             k {:expected-len (bytes-len expected)
                                :actual-len (bytes-len (:body r))
                                :expected-sha (sha256-hex expected)
                                :actual-sha (when (:body r)
                                              (sha256-hex (:body r)))})))

            (= 404 (:status r))
            (assoc op :type :ok :value (independent/tuple k :missing))

            (nil? (:status r))
            (assoc op :type :info :error (:error r))

            :else
            (assoc op :type :info :error (str "read-att-http-" (:status r)))))

        :read-inline
        (let [expected (attachment-bytes spec)
              r (safe-http #(http/get (str (doc-url port k) "?attachments=true")
                                      http-opts))]
          (cond
            (= 200 (:status r))
            (let [att (get-in (:body r) [:_attachments :blob])
                  decoded (try
                            (when-let [d (get att :data)] (b64-decode d))
                            (catch Exception _ nil))
                  ct (get att :content_type)]
              (if (and (bytes-equal? expected decoded) (= (:ct spec) ct))
                (assoc op :type :ok :value (independent/tuple k :match))
                (assoc op :type :fail :error :inline-mismatch
                       :value (independent/tuple
                               k {:content-type ct
                                  :expected-content-type (:ct spec)
                                  :data-present (some? decoded)
                                  :expected-len (bytes-len expected)
                                  :actual-len (bytes-len decoded)}))))

            (= 404 (:status r))
            (assoc op :type :ok :value (independent/tuple k :missing))

            (nil? (:status r))
            (assoc op :type :info :error (:error r))

            :else
            (assoc op :type :info :error (str "read-inline-http-" (:status r)))))

        (assoc op :type :fail :error :unsupported-op)))))

(defn attachment-ops
  "A finite operation set for gen/cycle.  Every index has a stable id and
  payload, so a cycle re-writes the same bytes through the normal _rev CAS
  path instead of creating an ever-growing set of documents."
  []
  (vec
   (mapcat (fn [i]
             (let [k (str "att-" i)
                   spec (attachment-spec i)
                   ops [{:type :invoke :f :attach :value [k spec]}
                        {:type :invoke :f :read-att :value [k spec]}]]
               (cond-> ops
                 (pos? i)
                 (conj (let [j (rand-int i)]
                         {:type :invoke :f :read-att
                          :value [(str "att-" j) (attachment-spec j)]}))

                 (zero? (mod i 5))
                 (conj {:type :invoke :f :read-inline :value [k spec]}))))
           (range 4000))))

(defn signal-pid!
  [pid-file signal]
  (control/on node
    (control/exec :bash "-lc"
                  (str "if [ -f " pid-file " ]; then kill -" signal
                       " $(cat " pid-file ") 2>/dev/null || true; fi"))))

(defn http-ready?
  [p]
  (try
    (= 200 (:status (http/get (str (base-url p) "/")
                              {:throw-exceptions false
                               :as :json
                               :connection-timeout 250
                               :socket-timeout 500})))
    (catch Exception _ false)))

(defn wait-http-ready!
  "Poll the server from the test runner.  Unlike wait-health!, this does not
  depend on the exit status of a remote shell command, so a dead server is
  never mistaken for a live one."
  [p timeout-ms]
  (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (cond
        (http-ready? p) true
        (< (System/currentTimeMillis) deadline)
        (do (Thread/sleep 250) (recur))
        :else false))))

(defn ensure-checkable-server!
  "Bring a single-node suite back to a state where the final-state checker can
  inspect it.  Fault schedules may end while the server is killed, paused or
  out of disk; this recovery is verification setup, not a workload operation."
  [port db]
  (try (heal! port) (catch Exception _ nil))
  (try (signal-pid! (:pid-file db) "CONT") (catch Exception _ nil))
  (when (:disk? db)
    (try (free-disk! db) (catch Exception _ nil)))
  (if (wait-http-ready! port 3000)
    false
    (do
      (try (stop-server! db) (catch Exception _ nil))
      (start-server! db)
      (when-not (wait-http-ready! port 15000)
        (throw (ex-info "server did not become reachable for final-state check"
                        {:port port})))
      true)))

(defn verify-attachment-key
  "Verify one acknowledged write: raw bytes always, plus the inline
  ?attachments=true representation for a deterministic sample."
  [port k spec index]
  (let [expected (attachment-bytes spec)
        raw (safe-http #(http/get (str (doc-url port k) "/blob")
                                  (assoc http-opts :as :byte-array)))]
    (cond
      (nil? (:status raw))
      {:status :unavailable :detail (:error raw)}

      (= 404 (:status raw))
      {:status :missing :detail :http-404}

      (not= 200 (:status raw))
      {:status :unavailable :detail (str "raw-http-" (:status raw))}

      (not (bytes-equal? expected (:body raw)))
      {:status :mismatch
       :detail {:kind :raw
                :expected-len (bytes-len expected)
                :actual-len (bytes-len (:body raw))
                :expected-sha (sha256-hex expected)
                :actual-sha (when (:body raw) (sha256-hex (:body raw)))}}

      :else
      (if-not (or (< index 50) (zero? (mod index 8)))
        {:status :ok}
        (let [r (safe-http #(http/get (str (doc-url port k) "?attachments=true")
                                      http-opts))]
          (cond
            (nil? (:status r))
            {:status :unavailable :detail (:error r)}

            (= 404 (:status r))
            {:status :missing :detail :inline-404}

            (not= 200 (:status r))
            {:status :unavailable :detail (str "inline-http-" (:status r))}

            :else
            (let [att (get-in (:body r) [:_attachments :blob])
                  decoded (try
                            (when-let [d (get att :data)] (b64-decode d))
                            (catch Exception _ nil))
                  ct (get att :content_type)]
              (if (and (bytes-equal? expected decoded) (= (:ct spec) ct))
                {:status :ok :inline true}
                {:status :mismatch
                 :detail {:kind :inline
                          :content-type ct
                          :expected-content-type (:ct spec)
                          :data-present (some? decoded)}}))))))))

(defrecord AttachmentChecker [port db]
  checker/Checker
  (check [_this _test history _opts]
    (let [failures (filterv #(= :fail (:type %)) history)
          acked (reduce (fn [m op]
                          (if (and (= :ok (:type op))
                                   (= :attach (:f op))
                                   (vector? (:value op)))
                            (assoc m (first (:value op)) (second (:value op)))
                            m))
                        {}
                        history)
          info-writes (count (filter #(and (= :info (:type %))
                                            (= :attach (:f %)))
                                     history))
          restarted? (try (ensure-checkable-server! port db)
                          (catch Exception _ nil))
          base {:acked-writes (count acked)
                :indeterminate-writes info-writes
                :failed-ops (count failures)
                :server-restarted? (boolean restarted?)}]
      (if (empty? acked)
        (assoc base :valid? false :error "no acknowledged attachment writes")
        (let [deadline (+ (System/currentTimeMillis) 30000)
              indexed (vec (map-indexed vector (sort (keys acked))))]
          (loop [pending indexed
                 verified 0
                 inline-checks 0]
            (if (empty? pending)
              {:valid? (empty? failures)
               :acked-writes (count acked)
               :indeterminate-writes info-writes
               :failed-ops (count failures)
               :raw-verified verified
               :inline-checks inline-checks
               :server-restarted? (boolean restarted?)
               :missing []
               :mismatched []}
              (let [results (mapv (fn [[index k]]
                                    [[index k]
                                     (verify-attachment-key
                                      port k (get acked k) index)])
                                  pending)
                    good (filterv (fn [[_ r]] (= :ok (:status r))) results)
                    retry (filterv (fn [[_ r]] (not= :ok (:status r))) results)
                    inline-done (count (filter (fn [[_ r]] (:inline r))
                                               good))]
                (if (and (seq retry)
                         (< (System/currentTimeMillis) deadline))
                  (do
                    (Thread/sleep 500)
                    (recur (mapv first retry)
                           (+ verified (count good))
                           (+ inline-checks inline-done)))
                  {:valid? (and (empty? failures) (empty? retry))
                   :acked-writes (count acked)
                   :indeterminate-writes info-writes
                   :failed-ops (count failures)
                   :raw-verified (+ verified (count good))
                   :inline-checks (+ inline-checks inline-done)
                   :server-restarted? (boolean restarted?)
                   :missing (vec
                             (take 10
                                   (keep (fn [[[_index k] r]]
                                           (when (= :missing (:status r))
                                             {:key k :detail (:detail r)}))
                                         retry)))
                   :mismatched (vec
                                (take 10
                                      (keep (fn [[[_index k] r]]
                                              (when (= :mismatch (:status r))
                                                {:key k :detail (:detail r)}))
                                            retry)))})))))))))

(defrecord AttachmentNemesis [db]
  nemesis/Nemesis
  (setup! [this _test] this)
  (teardown! [this _test]
    (try (heal! (:port db)) (catch Exception _ nil))
    (try (signal-pid! (:pid-file db) "CONT") (catch Exception _ nil))
    this)

  (invoke! [_this _test op]
    (try
      (case (:f op)
        :kill (do (stop-server! db)
                  (assoc op :type :info :value :killed))
        :start (do (start-server! db)
                   (assoc op :type :info :value :started))
        :pause (do (signal-pid! (:pid-file db) "STOP")
                   (assoc op :type :info :value :paused))
        :resume (do (signal-pid! (:pid-file db) "CONT")
                    (assoc op :type :info :value :resumed))
        :fill (do (fill-disk! db)
                  (assoc op :type :info :value :filled))
        :free (do (free-disk! db)
                  (assoc op :type :info :value :freed))
        :partition (do (partition! (:port db))
                       (assoc op :type :info :value :partitioned))
        :heal (do (heal! (:port db))
                  (assoc op :type :info :value :healed))
        (assoc op :type :info :value :unknown))
      (catch Exception e
        (assoc op :type :info :error (or (.getMessage e) (str (class e))))))))

;; ---------------------------------------------------------------------------
;; Replication topology workloads
;; ---------------------------------------------------------------------------

(defn server-ready?
  [p]
  (try
    (= 200 (:status (http/get (str (base-url p) "/" db-name)
                              (assoc http-opts :socket-timeout 500))))
    (catch Exception _ false)))

(defn record-rep-attempt
  [stats label]
  (swap! stats update-in [label :attempts] (fnil inc 0)))

(defn record-rep-ok
  [stats label]
  (swap! stats update-in [label :ok] (fnil inc 0)))

(defn record-rep-fail
  [stats label error]
  (swap! stats
         (fn [s]
           (-> s
               (update-in [label :fail] (fnil inc 0))
               (assoc-in [label :last-error] error)))))

(defn start-push-replicator!
  "Push loop for one target.  Like the existing single-target replicator but
  with per-peer statistics, so a fan-out can report each target separately."
  [source-port target-port stats label]
  (let [running (atom true)]
    (future
      (while @running
        (if-not (server-ready? source-port)
          (Thread/sleep 100)
          (do
            (record-rep-attempt stats label)
            (try
              (let [r (http/post (str (base-url source-port) "/_replicate")
                                 (assoc http-opts
                                        :content-type :json
                                        :body (json/generate-string
                                                {"source" db-name
                                                 "target" (str (base-url target-port)
                                                               "/" db-name)})))]
                (if (= 200 (:status r))
                  (record-rep-ok stats label)
                  (record-rep-fail stats label (str "http-" (:status r)))))
              (catch Exception e
                (record-rep-fail stats label
                                 (or (.getMessage e) (str (class e))))))
            (Thread/sleep 250)))))
    (fn [] (reset! running false))))

(defn start-pull-replicator!
  "Target-initiated pull loop.  The POST goes to the target's /_replicate with
  a source URL, exercising the opposite direction from the push suites."
  [source-port target-port stats label]
  (let [running (atom true)]
    (future
      (while @running
        (if-not (server-ready? target-port)
          (Thread/sleep 100)
          (do
            (record-rep-attempt stats label)
            (try
              (let [r (http/post (str (base-url target-port) "/_replicate")
                                 (assoc http-opts
                                        :content-type :json
                                        :body (json/generate-string
                                                {"source" (str (base-url source-port)
                                                               "/" db-name)
                                                 "target" db-name})))]
                (if (= 200 (:status r))
                  (record-rep-ok stats label)
                  (record-rep-fail stats label (str "http-" (:status r)))))
              (catch Exception e
                (record-rep-fail stats label
                                 (or (.getMessage e) (str (class e))))))
            (Thread/sleep 250)))))
    (fn [] (reset! running false))))

(defn ensure-replicator-docs!
  "Create the continuous replication jobs in the source's _replicator
  database.  The server's scheduler owns retries from here on."
  [source targets]
  (let [base (base-url (:port source))]
    (http/put (str base "/_replicator")
              {:throw-exceptions false :as :json})
    (doseq [[label target] targets]
      (let [r (http/put (str base "/_replicator/rep-" (name label))
                        (assoc http-opts
                               :content-type :json
                               :body (json/generate-string
                                       {"source" db-name
                                        "target" (str (base-url (:port target))
                                                      "/" db-name)
                                        "continuous" true})))]
        (when-not (#{201 202} (:status r))
          (throw (ex-info "cannot create _replicator doc"
                          {:label label :response (response r)})))))
    ;; Give the scheduler at least one tick to pick the jobs up.
    (Thread/sleep 2500)))

(defrecord ReplicationFleetDB [source targets mode stop-atom stats]
  db/DB
  (setup! [this _test node]
    (db/setup! source _test node)
    (doseq [[_ target] targets]
      (db/setup! target _test node))
    (doseq [[_ target] targets]
      (ensure-db! (:port target)))
    (reset! stats
            (into {}
                  (map (fn [[label _]]
                         [label {:attempts 0 :ok 0 :fail 0 :last-error nil}])
                       targets)))
    (reset! stop-atom
            (case mode
              :push
              (mapv (fn [[label target]]
                      (start-push-replicator! (:port source) (:port target)
                                              stats label))
                    targets)
              :pull
              (mapv (fn [[label target]]
                      (start-pull-replicator! (:port source) (:port target)
                                              stats label))
                    targets)
              :continuous
              (do (ensure-replicator-docs! source targets) [])
              []))
    this)

  (teardown! [this _test node]
    (doseq [stop @stop-atom]
      (try (stop) (catch Exception _ nil)))
    (reset! stop-atom [])
    (doseq [[_ target] targets]
      (db/teardown! target _test node))
    (db/teardown! source _test node)))

(defrecord FleetNemesis [servers]
  nemesis/Nemesis
  (setup! [this _test] this)
  (teardown! [this _test]
    (doseq [[_ db] servers]
      (try (heal! (:port db)) (catch Exception _ nil))
      (try (signal-pid! (:pid-file db) "CONT") (catch Exception _ nil)))
    this)

  (invoke! [_this _test op]
    (let [name (:value op)
          db (get servers name)]
      (try
        (when (nil? db)
          (throw (ex-info (str "unknown node " name) {:op op})))
        (case (:f op)
          :kill-node (do (stop-server! db)
                         (assoc op :type :info :value [:killed name]))
          :start-node (do (start-server! db)
                          (assoc op :type :info :value [:started name]))
          :pause-node (do (signal-pid! (:pid-file db) "STOP")
                          (assoc op :type :info :value [:paused name]))
          :resume-node (do (signal-pid! (:pid-file db) "CONT")
                           (assoc op :type :info :value [:resumed name]))
          :partition-node (do (partition! (:port db))
                              (assoc op :type :info :value [:partitioned name]))
          :heal-node (do (heal! (:port db))
                         (assoc op :type :info :value [:healed name]))
          :fill-node (do (fill-disk! db)
                         (assoc op :type :info :value [:filled name]))
          :free-node (do (free-disk! db)
                         (assoc op :type :info :value [:freed name]))
          (assoc op :type :info :value [:unknown (:f op)]))
        (catch Exception e
          (assoc op :type :info
                 :error (or (.getMessage e) (str (class e)))))))))

(defn replicator-doc-states
  [source-port targets]
  (into {}
        (keep (fn [[label _]]
                (let [r (safe-http
                         #(http/get (str (base-url source-port)
                                         "/_replicator/rep-" (name label))
                                    http-opts))]
                  (when (= 200 (:status r))
                    [label (select-keys (:body r)
                                        [:_replication_state
                                         :_replication_failures
                                         :_replication_state_time])]))))
        targets))

(defn ensure-checkable-fleet!
  "Restart/resume any node that a fault schedule left down.  Runs before the
  final convergence check so a killed node cannot make two NULL document
  states look equal."
  [servers]
  (doseq [[_ db] servers]
    (try (heal! (:port db)) (catch Exception _ nil))
    (try (signal-pid! (:pid-file db) "CONT") (catch Exception _ nil)))
  (let [restarted (atom [])]
    (doseq [[label db] servers]
      (when-not (wait-http-ready! (:port db) 2500)
        (try (stop-server! db) (catch Exception _ nil))
        (start-server! db)
        (when-not (wait-http-ready! (:port db) 15000)
          (throw (ex-info "node did not become reachable for convergence check"
                          {:node label :port (:port db)})))
        (swap! restarted conj label)))
    @restarted))

(defrecord FleetConvergenceChecker [source-port targets stats servers]
  checker/Checker
  (check [_this _test history _opts]
    (let [ks (->> history
                  (keep #(when (vector? (:value %)) (first (:value %))))
                  distinct
                  vec)
          restarted (ensure-checkable-fleet! servers)
          deadline (+ (System/currentTimeMillis) 30000)]
      (loop []
        (let [pairs (for [[label target] targets
                          k ks]
                      [label k (doc-state source-port k) (doc-state (:port target) k)])
              diverged (remove (fn [[_label _k s t]]
                                 (and (= (:rev s) (:rev t))
                                      (= (:value s) (:value t))))
                               pairs)]
          (if (empty? diverged)
            {:valid? true
             :keys (count ks)
             :targets (mapv first targets)
             :server-restarted? restarted
             :replication @stats
             :replicator-docs (replicator-doc-states source-port targets)}
            (if (< (System/currentTimeMillis) deadline)
              (do (Thread/sleep 250) (recur))
              {:valid? false
               :keys (count ks)
               :targets (mapv first targets)
               :server-restarted? restarted
               :diverged (vec (take 10 diverged))
               :replication @stats
               :replicator-docs (replicator-doc-states source-port targets)})))))))

(defn fleet-checker
  [history-checker source-port targets stats servers]
  (checker/compose
    {:history history-checker
     :convergence (->FleetConvergenceChecker source-port targets stats servers)}))

(defn schedule-for [suite]
  (case suite
    :kill (gen/cycle [(gen/sleep 4)
                      {:type :info :f :kill}
                      (gen/sleep 1)
                      {:type :info :f :start}])
    :pause (gen/cycle [(gen/sleep 4)
                       {:type :info :f :pause}
                       (gen/sleep 2)
                       {:type :info :f :resume}])
    :partition (gen/cycle [(gen/sleep 4)
                           {:type :info :f :partition}
                           (gen/sleep 2)
                           {:type :info :f :heal}])
    :disk (gen/cycle [(gen/sleep 4)
                      {:type :info :f :fill}
                      (gen/sleep 2)
                      {:type :info :f :free}
                      (gen/sleep 1)
                      {:type :info :f :kill}
                      (gen/sleep 1)
                      {:type :info :f :start}])
    :replication (gen/cycle [(gen/sleep 4)
                             {:type :info :f :kill-target}
                             (gen/sleep 3)
                             {:type :info :f :start-target}
                             (gen/sleep 2)
                             {:type :info :f :partition}
                             (gen/sleep 3)
                             {:type :info :f :heal}
                             (gen/sleep 2)
                             {:type :info :f :kill-source}
                             (gen/sleep 1)
                             {:type :info :f :start-source}
                             (gen/sleep 1)])
    :attachments (gen/cycle [(gen/sleep 3)
                             {:type :info :f :pause}
                             (gen/sleep 2)
                             {:type :info :f :resume}
                             (gen/sleep 2)
                             {:type :info :f :partition}
                             (gen/sleep 2)
                             {:type :info :f :heal}
                             (gen/sleep 2)
                             {:type :info :f :kill}
                             (gen/sleep 1)
                             {:type :info :f :start}
                             (gen/sleep 2)
                             {:type :info :f :fill}
                             (gen/sleep 2)
                             {:type :info :f :free}
                             (gen/sleep 2)])
    nil))

(defn fleet-schedule
  [suite]
  (case suite
    :pull (gen/cycle [(gen/sleep 4)
                      {:type :info :f :pause-node :value :source}
                      (gen/sleep 2)
                      {:type :info :f :resume-node :value :source}
                      (gen/sleep 2)
                      {:type :info :f :kill-node :value :target}
                      (gen/sleep 3)
                      {:type :info :f :start-node :value :target}
                      (gen/sleep 2)
                      {:type :info :f :partition-node :value :source}
                      (gen/sleep 3)
                      {:type :info :f :heal-node :value :source}
                      (gen/sleep 2)
                      {:type :info :f :kill-node :value :source}
                      (gen/sleep 1)
                      {:type :info :f :start-node :value :source}
                      (gen/sleep 2)])
    :continuous (gen/cycle [(gen/sleep 4)
                            {:type :info :f :kill-node :value :target}
                            (gen/sleep 3)
                            {:type :info :f :start-node :value :target}
                            (gen/sleep 2)
                            {:type :info :f :partition-node :value :target}
                            (gen/sleep 3)
                            {:type :info :f :heal-node :value :target}
                            (gen/sleep 2)
                            {:type :info :f :kill-node :value :source}
                            (gen/sleep 2)
                            {:type :info :f :start-node :value :source}
                            (gen/sleep 2)])
    :multipeer (gen/cycle [(gen/sleep 4)
                           {:type :info :f :kill-node :value :target-a}
                           (gen/sleep 3)
                           {:type :info :f :start-node :value :target-a}
                           (gen/sleep 2)
                           {:type :info :f :partition-node :value :target-b}
                           (gen/sleep 3)
                           {:type :info :f :heal-node :value :target-b}
                           (gen/sleep 2)
                           {:type :info :f :kill-node :value :source}
                           (gen/sleep 2)
                           {:type :info :f :start-node :value :source}
                           (gen/sleep 2)])
    nil))

(defn single-test
  [suite]
  (let [disk? (= suite :disk)
        db (->ZouchDB port
                      (if disk? (str disk-mount "/data") data-dir)
                      pid-file log-file disk?)
        schedule (schedule-for suite)
        base (merge tests/noop-test
                    {:name (str "zouch-" (name suite))
                     :nodes [node]
                     :concurrency 6
                     :ssh {:username "ubuntu"
                           :private-key-path (str (System/getProperty "user.home") "/.ssh/jepsen_rsa")
                           :strict-host-key-checking false}
                     :remote control/ssh
                     :db db
                     :client (->ZouchClient port)
                     :nemesis (if schedule
                                (->ZouchNemesis db)
                                nemesis/noop)}
                    (lreg/test {:nodes [node]}))]
    (update base :generator
            (fn [g]
              (let [g (if schedule
                        (gen/nemesis schedule g)
                        g)]
                (->> g
                     (gen/time-limit (if (= suite :smoke) 15 30))
                     (gen/limit (if (= suite :smoke) 4000 12000))))))))

(defn replication-test
  []
  (let [source (->ZouchDB port source-data-dir source-pid-file source-log-file false)
        target (->ZouchDB target-port target-data-dir target-pid-file target-log-file false)
        db (->ReplicationDB source target (atom nil))
        base (merge tests/noop-test
                    {:name "zouch-replication"
                     :nodes [node]
                     :concurrency 6
                     :ssh {:username "ubuntu"
                           :private-key-path (str (System/getProperty "user.home") "/.ssh/jepsen_rsa")
                           :strict-host-key-checking false}
                     :remote control/ssh
                     :db db
                     :client (->ZouchClient port)
                     :nemesis (->ReplicationNemesis source target)}
                    (lreg/test {:nodes [node]}))]
    (assoc base
           :checker (replication-checker (:checker base) port target-port)
           :generator (->> (:generator base)
                           (gen/nemesis (schedule-for :replication))
                           (gen/time-limit 30)
                           (gen/limit 12000)))))

(defn attachments-test
  []
  (let [db (->ZouchDB port (str disk-mount "/data") pid-file log-file true)
        base (merge tests/noop-test
                    {:name "zouch-attachments"
                     :nodes [node]
                     :concurrency 8
                     :ssh {:username "ubuntu"
                           :private-key-path (str (System/getProperty "user.home") "/.ssh/jepsen_rsa")
                           :strict-host-key-checking false}
                     :remote control/ssh
                     :db db
                     :client (->AttachmentClient port)
                     :nemesis (->AttachmentNemesis db)
                     :leave-db-running? true
                     :leave-db-running true
                     :checker (checker/compose
                               {:attachments (->AttachmentChecker port db)})})]
    (assoc base
           :generator (->> (gen/cycle (attachment-ops))
                           (gen/nemesis (schedule-for :attachments))
                           (gen/time-limit 30)
                           (gen/limit 12000)))))

(defn fleet-test
  [suite]
  (let [source (->ZouchDB port source-data-dir source-pid-file source-log-file false)
        target-a (->ZouchDB target-port target-data-dir target-pid-file target-log-file false)
        target-b (->ZouchDB target2-port target2-data-dir target2-pid-file target2-log-file false)
        targets (if (= suite :multipeer)
                  [[:target-a target-a] [:target-b target-b]]
                  [[:target target-a]])
        mode (case suite
               :pull :pull
               :continuous :continuous
               :multipeer :push)
        stats (atom {})
        db (->ReplicationFleetDB source targets mode (atom nil) stats)
        servers (into {:source source} targets)
        base (merge tests/noop-test
                    {:name (str "zouch-" (name suite))
                     :nodes [node]
                     :concurrency 6
                     :ssh {:username "ubuntu"
                           :private-key-path (str (System/getProperty "user.home") "/.ssh/jepsen_rsa")
                           :strict-host-key-checking false}
                     :remote control/ssh
                     :db db
                     :client (->ZouchClient port)
                     :nemesis (->FleetNemesis servers)
                     :leave-db-running? true
                     :leave-db-running true}
                    (lreg/test {:nodes [node]}))]
    (assoc base
           :checker (fleet-checker (:checker base) port targets stats servers)
           :generator (->> (:generator base)
                           (gen/nemesis (fleet-schedule suite))
                           (gen/time-limit 35)
                           (gen/limit 14000)))))

(defn zouch-test
  [suite]
  (cond
    (#{:pull :continuous :multipeer} suite) (fleet-test suite)
    (= suite :attachments) (attachments-test)
    (= suite :replication) (replication-test)
    :else (single-test suite)))

(defn cleanup-db!
  "New live-state suites set :leave-db-running? so their checkers can inspect
  the servers after the fault schedule ends.  Tear those servers down only
  after analysis has completed."
  [test]
  (try
    (control/with-remote (:remote test)
      (control/with-ssh (:ssh test)
        (db/teardown! (:db test) test node)))
    (catch Exception e
      (println "cleanup warning:" (or (.getMessage e) (str (class e)))))))

(defn -main [& args]
  (let [suite (keyword (or (first args) "kill"))
        _ (when-not (#{:smoke :kill :pause :partition :disk :replication
                       :attachments :pull :continuous :multipeer} suite)
            (println "Unknown suite:" suite)
            (System/exit 2))
        test (zouch-test suite)]
    (try
      (let [result (jepsen/run! test)
            valid? (get-in result [:results :valid?])]
        (println "Jepsen suite" (name suite) "valid?" valid?)
        (when (= suite :replication)
          (println "Replication stats" @replication-stats))
        (when (= suite :attachments)
          (println "Attachment checker" (get-in result [:results :attachments])))
        (when (#{:pull :continuous :multipeer} suite)
          (println "Convergence" (dissoc (get-in result [:results :convergence])
                                         :diverged)))
        (cleanup-db! test)
        (shutdown-agents)
        (System/exit (if (= true valid?) 0 1)))
      (catch Throwable t
        (cleanup-db! test)
        (throw t)))))
