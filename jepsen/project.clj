(defproject zouch-jepsen "0.1.0"
  :description "Jepsen smoke and fault-injection tests for Zouch"
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [jepsen "0.3.15"]
                 [clj-http "3.13.0"]
                 [cheshire "5.13.0"]]
  :main zouch.jepsen
  :jvm-opts ["-Xmx1g" "-Djava.awt.headless=true"]
  :profiles {:uberjar {:aot :all}})
