#!/bin/bash
set -x

BLUE='\033[1;34m'
NC='\033[0m'
occlum_glibc=/opt/occlum/glibc/lib
# occlum-node IP
HOST_IP=`cat /etc/hosts | grep $HOSTNAME | awk '{print $1}'`

check_sgx_dev() {
    if [ -c "/dev/sgx/enclave" ]; then
        echo "/dev/sgx/enclave is ready"
    elif [ -c "/dev/sgx_enclave" ]; then
        echo "/dev/sgx/enclave not ready, try to link to /dev/sgx_enclave"
        mkdir -p /dev/sgx
        ln -s /dev/sgx_enclave /dev/sgx/enclave
    else
        echo "both /dev/sgx/enclave /dev/sgx_enclave are not ready, please check the kernel and driver"
    fi

    if [ -c "/dev/sgx/provision" ]; then
        echo "/dev/sgx/provision is ready"
    elif [ -c "/dev/sgx_provision" ]; then
        echo "/dev/sgx/provision not ready, try to link to /dev/sgx_provision"
        mkdir -p /dev/sgx
        ln -s /dev/sgx_provision /dev/sgx/provision
    else
        echo "both /dev/sgx/provision /dev/sgx_provision are not ready, please check the kernel and driver"
    fi

    ls -al /dev/sgx
}

init_instance() {
    # check and fix sgx device
    check_sgx_dev
    # Init Occlum instance
    cd /opt
    # check if occlum_spark exists
    [[ -d occlum_spark ]] || mkdir occlum_spark
    cd occlum_spark
    occlum init
    new_json="$(jq '.resource_limits.user_space_size = "SGX_MEM_SIZE" |
        .resource_limits.max_num_of_threads = "SGX_THREAD" |
        .process.default_heap_size = "SGX_HEAP" |
        .metadata.debuggable = "ENABLE_SGX_DEBUG" |
        .resource_limits.kernel_space_heap_size="SGX_KERNEL_HEAP" |
        .entry_points = [ "/usr/lib/jvm/java-8-openjdk-amd64/bin", "/bin" ] |
        .env.untrusted = [ "DMLC_TRACKER_URI", "SPARK_DRIVER_URL", "SPARK_TESTING" , "_SPARK_AUTH_SECRET" ] |
        .env.default = [ "PYTHONHOME=/opt/python-occlum","LD_LIBRARY_PATH=/usr/lib/jvm/java-8-openjdk-amd64/lib/server:/usr/lib/jvm/java-8-openjdk-amd64/lib:/usr/lib/jvm/java-8-openjdk-amd64/../lib:/lib","SPARK_CONF_DIR=/opt/spark/conf","SPARK_ENV_LOADED=1","PYTHONHASHSEED=0","SPARK_HOME=/opt/spark","SPARK_SCALA_VERSION=2.12","SPARK_JARS_DIR=/opt/spark/jars","LAUNCH_CLASSPATH=/bin/jars/*",""]' Occlum.json)" && \
    echo "${new_json}" > Occlum.json
    echo "SGX_MEM_SIZE ${SGX_MEM_SIZE}"

    #copy python lib
    copy_bom -f /opt/python-glibc.yaml --root image --include-dir /opt/occlum/etc/template
    # enable tmp hostfs
    # --conf spark.executorEnv.USING_TMP_HOSTFS=true \
    if [[ $USING_TMP_HOSTFS == "true" ]]; then
        echo "use tmp hostfs"
        mkdir ./shuffle
        edit_json="$(cat Occlum.json | jq '.mount+=[{"target": "/tmp","type": "hostfs","source": "./shuffle"}]')" && \
        echo "${edit_json}" > Occlum.json
    fi

    if [[ -z "$META_SPACE" ]]; then
        echo "META_SPACE not set, using default value 256m"
        META_SPACE=256m
    else
        echo "META_SPACE=$META_SPACE"
    fi

    if [[ -z "$SGX_MEM_SIZE" ]]; then
        sed -i "s/SGX_MEM_SIZE/20GB/g" Occlum.json
    else
        sed -i "s/SGX_MEM_SIZE/${SGX_MEM_SIZE}/g" Occlum.json
    fi

    if [[ -z "$SGX_THREAD" ]]; then
        sed -i "s/\"SGX_THREAD\"/512/g" Occlum.json
    else
        sed -i "s/\"SGX_THREAD\"/${SGX_THREAD}/g" Occlum.json
    fi

    if [[ -z "$SGX_HEAP" ]]; then
        sed -i "s/SGX_HEAP/512MB/g" Occlum.json
    else
        sed -i "s/SGX_HEAP/${SGX_HEAP}/g" Occlum.json
    fi

    if [[ -z "$SGX_KERNEL_HEAP" ]]; then
        sed -i "s/SGX_KERNEL_HEAP/1GB/g" Occlum.json
    else
        sed -i "s/SGX_KERNEL_HEAP/${SGX_KERNEL_HEAP}/g" Occlum.json
    fi

    # check attestation setting
    if [ -z "$ATTESTATION" ]; then
        echo "[INFO] Attestation is disabled!"
        ATTESTATION="false"
    fi

    if [[ $ATTESTATION == "true" ]]; then
        if [[ $PCCS_URL == "" ]]; then
           echo "[ERROR] Attestation set to true but NO PCCS"
           exit 1
        else
           echo 'PCCS_URL='${PCCS_URL}'/sgx/certification/v3/' > /etc/sgx_default_qcnl.conf
           echo 'USE_SECURE_CERT=FALSE' >> /etc/sgx_default_qcnl.conf
           cd /root/demos/remote_attestation/dcap/
           #build .c file
           bash ./get_quote_on_ppml.sh
           cd /opt/occlum_spark
           # dir need to exit when writing quote
           mkdir -p /opt/occlum_spark/image/etc/occlum_attestation/
           #copy bom to generate quote
           copy_bom -f /root/demos/remote_attestation/dcap/dcap-ppml.yaml --root image --include-dir /opt/occlum/etc/template
        fi
    fi

    # check occlum log level for docker
    if [[ -z "$ENABLE_SGX_DEBUG" ]]; then
        echo "No ENABLE_SGX_DEBUG specified, set to off."
        export ENABLE_SGX_DEBUG=false
    fi
    export OCCLUM_LOG_LEVEL=off
    if [[ -z "$SGX_LOG_LEVEL" ]]; then
        echo "No SGX_LOG_LEVEL specified, set to off."
    else
        echo "Set SGX_LOG_LEVEL to $SGX_LOG_LEVEL"
        if [[ $SGX_LOG_LEVEL == "debug" ]] || [[ $SGX_LOG_LEVEL == "trace" ]]; then
            export ENABLE_SGX_DEBUG=true
            export OCCLUM_LOG_LEVEL=$SGX_LOG_LEVEL
        fi
    fi

    sed -i "s/\"ENABLE_SGX_DEBUG\"/$ENABLE_SGX_DEBUG/g" Occlum.json
    sed -i "s/#USE_SECURE_CERT=FALSE/USE_SECURE_CERT=FALSE/g" /etc/sgx_default_qcnl.conf
}

build_spark() {
    # Copy python examples and unzip python lib
    mkdir -p image/py-examples
    cp -rf /opt/py-examples/* image/py-examples
    # Copy JVM and class file into Occlum instance and build
    cd /opt/occlum_spark
    mkdir -p image/usr/lib/jvm
    cp -r /usr/lib/jvm/java-8-openjdk-amd64 image/usr/lib/jvm
    cp -rf /etc/java-8-openjdk image/etc/
    # Copy K8s secret
    mkdir -p image/var/run/secrets/
    cp -r /var/run/secrets/* image/var/run/secrets/
    ls image/var/run/secrets/kubernetes.io/serviceaccount/
    # Copy libs
    cp /lib/x86_64-linux-gnu/libz.so.1 image/lib
    cp /lib/x86_64-linux-gnu/libz.so.1 image/$occlum_glibc
    cp /lib/x86_64-linux-gnu/libtinfo.so.5 image/$occlum_glibc
    cp /lib/x86_64-linux-gnu/libnss*.so.2 image/$occlum_glibc
    cp /lib/x86_64-linux-gnu/libresolv.so.2 image/$occlum_glibc
    cp $occlum_glibc/libdl.so.2 image/$occlum_glibc
    cp $occlum_glibc/librt.so.1 image/$occlum_glibc
    cp $occlum_glibc/libm.so.6 image/$occlum_glibc
    # Copy libhadoop
    cp /opt/libhadoop.so image/lib
    # Prepare Spark
    mkdir -p image/opt/spark
    cp -rf $SPARK_HOME/* image/opt/spark/
    # Copy etc files
    cp -rf /etc/hosts image/etc/
    echo "$HOST_IP occlum-node" >> image/etc/hosts
    # cat image/etc/hosts

    cp -rf /etc/hostname image/etc/
    cp -rf /etc/ssl image/etc/
    cp -rf /etc/passwd image/etc/
    cp -rf /etc/group image/etc/
    cp -rf /etc/nsswitch.conf image/etc/

    # Prepare BigDL
    mkdir -p image/bin/jars
    cp -f $BIGDL_HOME/jars/* image/bin/jars
    cp -rf /opt/spark-source image/opt/

    # Build
    occlum build

    #before start occlum app after occlum build
    if [[ $ATTESTATION == "true" ]]; then
        if [[ $PCCS_URL == "" ]]; then
            echo "[ERROR] Attestation set to true but NO PCCS"
            exit 1
        else
            if [[ $RUNTIME_ENV == "driver" || $RUNTIME_ENV == "native" ]]; then
                #verify ehsm service
                cd /opt/
                bash verify-attestation-service.sh
                #register application

                #get mrenclave mrsigner
                MR_ENCLAVE_temp=$(bash print_enclave_signer.sh | grep mr_enclave)
                MR_ENCLAVE_temp_arr=(${MR_ENCLAVE_temp})
                export MR_ENCLAVE=${MR_ENCLAVE_temp_arr[1]}
                MR_SIGNER_temp=$(bash print_enclave_signer.sh | grep mr_signer)
                MR_SIGNER_temp_arr=(${MR_SIGNER_temp})
                export MR_SIGNER=${MR_SIGNER_temp_arr[1]}

                #register and get policy_Id
                policy_Id_temp=$(bash register.sh | grep policy_Id)
                policy_Id_temp_arr=(${policy_Id_temp})
                export policy_Id=${policy_Id_temp_arr[1]}
            fi
        fi
        #register error
        if [ $? -gt 0 ]; then
            echo "register error"
            exit 1;
        fi
    fi

    #attestation
    if [[ $ATTESTATION == "true" ]]; then
        if [[ $PCCS_URL == "" ]]; then
            echo "[ERROR] Attestation set to /root/demos/remote_attestation/dcaprue but NO PCCS"
            exit 1
        else
                #generate dcap quote
                cd /opt/occlum_spark
                occlum run /bin/dcap_c_test $REPORT_DATA
                echo "generate quote success"
                #attest quote
                occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                            -XX:-UseCompressedOops -XX:MaxMetaspaceSize=1g \
                            -XX:ActiveProcessorCount=4 \
                            -Divy.home="/tmp/.ivy" \
                            -Dos.name="Linux" \
                            -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:/bin/jars/*" \
                            -Xmx1g com.intel.analytics.bigdl.ppml.attestation.AttestationCLI \
                            -u $ATTESTATION_URL \
                            -i $APP_ID \
                            -k $API_KEY \
                            -O occlum \
                            -o $policy_Id
                if [ $? -gt 0 ]; then
                    echo "attest fail, exit"
                    exit 1;
                fi
                echo "verify success"
        fi
    fi
}

run_pyspark_pi() {
    init_instance spark
    build_spark
    cd /opt/occlum_spark
    echo -e "${BLUE}occlum run pyspark Pi${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=$META_SPACE \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -Djdk.lang.Process.launchMechanism=vfork \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*" \
                -Xmx512m org.apache.spark.deploy.SparkSubmit \
                /py-examples/pi.py
}

run_spark_pi() {
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run spark Pi${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=$META_SPACE \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*" \
                -Xmx512m org.apache.spark.deploy.SparkSubmit \
                --jars $SPARK_HOME/examples/jars/spark-examples_2.12-${SPARK_VERSION}.jar,$SPARK_HOME/examples/jars/scopt_2.12-3.7.1.jar \
                --class org.apache.spark.examples.SparkPi spark-internal
}

run_spark_unittest() {
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run spark unit test ${NC}"
    run_spark_unittest_only
}

run_spark_unittest_only() {
    export SPARK_TESTING=1
    cd /opt/occlum_spark
    mkdir -p data/olog
    echo -e "${BLUE}occlum run spark unit test only ${NC}"
    occlum start
    for suite in `cat /opt/sqlSuites`
    do occlum exec /usr/lib/jvm/java-8-openjdk-amd64/bin/java -Xmx24g \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
		-Djdk.lang.Process.launchMechanism=posix_spawn \
		-XX:MaxMetaspaceSize=$META_SPACE \
	        -Dspark.testing=true \
	        -Dspark.test.home=/opt/spark-source \
	        -Dspark.python.use.daemon=false \
	        -Dspark.python.worker.reuse=false \
	        -Dspark.driver.host=127.0.0.1 \
	        -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:$SPARK_HOME/test-jars/*:$SPARK_HOME/test-classes/"  \
	        org.scalatest.tools.Runner \
	        -s ${suite} \
	        -fF /host/data/olog/${suite}.txt
    done
	        #-Dspark.sql.warehouse.dir=hdfs://localhost:9000/111-spark-warehouse \
    occlum stop
}

run_spark_lenet_mnist(){
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run BigDL lenet mnist{NC}"
    echo -e "${BLUE}logfile=$log${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=256m \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:/bin/jars/*" \
                -Xmx10g org.apache.spark.deploy.SparkSubmit \
                --master 'local[4]' \
                --conf spark.driver.port=10027 \
                --conf spark.scheduler.maxRegisteredResourcesWaitingTime=5000000 \
                --conf spark.worker.timeout=600 \
                --conf spark.starvation.timeout=250000 \
                --conf spark.rpc.askTimeout=600 \
                --conf spark.blockManager.port=10025 \
                --conf spark.driver.host=127.0.0.1 \
                --conf spark.driver.blockManager.port=10026 \
                --conf spark.io.compression.codec=lz4 \
                --class com.intel.analytics.bigdl.dllib.models.lenet.Train \
                --driver-memory 10G \
                /bin/jars/bigdl-dllib-spark_${SPARK_VERSION}-${BIGDL_VERSION}.jar \
                -f /host/data \
                $* | tee spark.local.sgx.log
}

run_spark_resnet_cifar(){
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run BigDL Resnet Cifar10${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=$META_SPACE \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:/bin/jars/*" \
                -Xmx10g org.apache.spark.deploy.SparkSubmit \
                --master 'local[4]' \
                --conf spark.driver.port=10027 \
                --conf spark.scheduler.maxRegisteredResourcesWaitingTime=5000000 \
                --conf spark.worker.timeout=600 \
                --conf spark.starvation.timeout=250000 \
                --conf spark.rpc.askTimeout=600 \
                --conf spark.blockManager.port=10025 \
                --conf spark.driver.host=127.0.0.1 \
                --conf spark.driver.blockManager.port=10026 \
                --conf spark.io.compression.codec=lz4 \
                --class com.intel.analytics.bigdl.dllib.models.resnet.TrainCIFAR10 \
                --driver-memory 10G \
                /bin/jars/bigdl-dllib-spark_${SPARK_VERSION}-${BIGDL_VERSION}.jar \
                -f /host/data \
                $* | tee spark.local.sgx.log
}

run_spark_tpch(){
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run BigDL spark tpch${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=$META_SPACE \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:/bin/jars/*" \
                -Xmx8g -Xms8g \
                org.apache.spark.deploy.SparkSubmit \
                --master 'local[4]' \
                --conf spark.driver.port=54321 \
                --conf spark.driver.memory=8g \
                --conf spark.driver.blockManager.port=10026 \
                --conf spark.blockManager.port=10025 \
                --conf spark.scheduler.maxRegisteredResourcesWaitingTime=5000000 \
                --conf spark.worker.timeout=600 \
                --conf spark.python.use.daemon=false \
                --conf spark.python.worker.reuse=false \
                --conf spark.network.timeout=10000000 \
                --conf spark.starvation.timeout=250000 \
                --conf spark.rpc.askTimeout=600 \
                --conf spark.sql.autoBroadcastJoinThreshold=-1 \
                --conf spark.io.compression.codec=lz4 \
                --conf spark.sql.shuffle.partitions=8 \
                --conf spark.speculation=false \
                --conf spark.executor.heartbeatInterval=10000000 \
                --conf spark.executor.instances=8 \
                --executor-cores 2 \
                --total-executor-cores 16 \
                --executor-memory 8G \
                --class main.scala.TpchQuery \
                --verbose \
                /bin/jars/spark-tpc-h-queries_2.12-1.0.jar \
                /host/data /host/data/output
}

run_spark_xgboost() {
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run BigDL Spark XGBoost${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=$META_SPACE \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:/bin/jars/*" \
                -Xmx10g -Xms10g org.apache.spark.deploy.SparkSubmit \
                --master local[4] \
                --conf spark.task.cpus=2 \
                --class com.intel.analytics.bigdl.dllib.example.nnframes.xgboost.xgbClassifierTrainingExampleOnCriteoClickLogsDataset \
                --num-executors 2 \
                --executor-cores 2 \
                --executor-memory 9G \
                --driver-memory 10G \
                /bin/jars/bigdl-dllib-spark_${SPARK_VERSION}-${BIGDL_VERSION}.jar \
                -i /host/data -s /host/data/model -t 2 -r 100 -d 2 -w 1
}

run_spark_gbt() {
    init_instance spark
    build_spark
    echo -e "${BLUE}occlum run BigDL Spark GBT${NC}"
    occlum run /usr/lib/jvm/java-8-openjdk-amd64/bin/java \
                -XX:-UseCompressedOops -XX:MaxMetaspaceSize=$META_SPACE \
                -XX:ActiveProcessorCount=4 \
                -Divy.home="/tmp/.ivy" \
                -Dos.name="Linux" \
                -cp "$SPARK_HOME/conf/:$SPARK_HOME/jars/*:/bin/jars/*" \
                -Xmx10g -Xms10g org.apache.spark.deploy.SparkSubmit \
                --master local[4] \
                --conf spark.task.cpus=2 \
                --class com.intel.analytics.bigdl.dllib.example.nnframes.gbt.gbtClassifierTrainingExampleOnCriteoClickLogsDataset \
                --num-executors 2 \
                --executor-cores 2 \
                --executor-memory 9G \
                --driver-memory 10G \
                /bin/jars/bigdl-dllib-spark_${SPARK_VERSION}-${BIGDL_VERSION}.jar \
                -i /host/data -s /host/data/model -I 100 -d 5
}


id=$([ -f "$pid" ] && echo $(wc -l < "$pid") || echo "0")

arg=$1
case "$arg" in
    init)
       export RUNTIME_ENV="native"
        init_instance
        build_spark
        ;;
    initDriver)
        export RUNTIME_ENV="driver"
        init_instance
        build_spark
        ;;
    initExecutor)
        # to do
        # now executor have to register again
        export RUNTIME_ENV="native"
        init_instance
        build_spark
        ;;
    pypi)
        run_pyspark_pi
        cd ../
        ;;
    pi)
        run_spark_pi
        cd ../
        ;;
    lenet)
        run_spark_lenet_mnist
        cd ../
        ;;
    ut)
        run_spark_unittest
        cd ../
        ;;
    ut_Only)
        run_spark_unittest_only
        cd ../
        ;;
    resnet)
        run_spark_resnet_cifar
        cd ../
        ;;
    tpch)
        run_spark_tpch
        cd ../
        ;;
    xgboost)
        run_spark_xgboost
        cd ../
        ;;
    gbt)
        run_spark_gbt
        cd ../
        ;;
esac