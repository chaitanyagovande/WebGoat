#!/bin/sh

callBase()
{
    TIMESTAMP=$(date +%F_%T | tr ':' '-')
    BUILDNAME="cg-mvn-base-webgoat"
    PROJECTKEY="cg-lab"
    DIRNAME="BaseWebGoat"

    echo "Base Script executed from: ${PWD} at $TIMESTAMP"
    #rm -Rf $DIRNAME
    #mkdir $DIRNAME
    #git clone https://github.com/jfrog/jfrog-maven-hello-world.git $DIRNAME
    #cd $DIRNAME
    #cp -f ../../jfrog-maven-hello-world/pom.xml .
    #cp -Rf ../../jfrog-maven-hello-world/.jfrog .

    jf mvn install --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY
    jf rt bce $BUILDNAME $TIMESTAMP --project $PROJECTKEY
    jf rt bag $BUILDNAME $TIMESTAMP --project $PROJECTKEY
    jf mvn deploy --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY
    jf rt bp $BUILDNAME $TIMESTAMP --project $PROJECTKEY
}

callDockerized()
{
    TIMESTAMP=$(date +%F_%T | tr ':' '-')
    BUILDNAME="cg-mvn-docker-webgoat"
    PROJECTKEY="cg-lab"
    DIRNAME="Dockerized"
    JF_PLAT="psazuse.jfrog.io"
    REPO="cg-lab-docker"
    IMAGE=$JF_PLAT/$REPO/$BUILDNAME
    JFROG_CLI_LOG_LEVEL=DEBUG
    #IMAGE="psazuse.jfrog.io/cg-oci/webgoat"

    echo "Dockerized Script executed from: ${PWD} at $TIMESTAMP with $DIRNAME"

    # OPTION 1: Build

        #docker image build -f my-files/Dockerfile-mvn -t ${{ vars.JF_NAME }}.jfrog.io/${{env.RT_DOCKER_REPO_VIRTUAL}}/${{ env.BUILD_NAME }}:${{ env.BUILD_ID}} --platform "${{env.DOCKER_BUILDX_PLATFORMS}}" --metadata-file "${{env.DOCKER_METADATA_JSON}}" --push .
    
    jf rt bc $BUILDNAME $TIMESTAMP

    jf rt bce $BUILDNAME $TIMESTAMP --project $PROJECTKEY
    jf rt bag $BUILDNAME $TIMESTAMP --project $DIRNAME
    
    docker image build -f ./Dockerfile -t $IMAGE:$TIMESTAMP --metadata-file ./metadata.json --push  .
    IMAGE_MOD="$(cat metadata.json | jq '.["containerimage.digest"]' | tr -d '"')"
    echo $IMAGE_MOD
    echo "$IMAGE:$TIMESTAMP@$IMAGE_MOD" > imagefile.json

    #jf docker push $IMAGE:$TIMESTAMP --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY

    jf rt bdc $REPO --image-file imagefile.json --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY
    jf rt bp $BUILDNAME $TIMESTAMP --project $PROJECTKEY

   

    
    
    
    
    # OPTION 2: Pull & Push

    

    #jf rt docker pull $IMAGE $REPO --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY
    #jf rt bce $BUILDNAME $TIMESTAMP --project $PROJECTKEY
    #jf rt bag $BUILDNAME $TIMESTAMP --project $DIRNAME

    #jf rt docker push $IMAGE $REPO --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY
    
    #IMAGE_DIGEST=`docker images --digests | grep webgoat | awk '$1 == "psazuse.jfrog.io/cg-oci/webgoat" {print $3}' | awk -F '[:]' '{print $2}'`
    #IMAGE_MOD=`echo $IMAGE | awk -F '[:]' '{ print $1 }'` #"psazuse.jfrog.io/cg-oci/cg-webgoat:latest"
    
    #echo $IMAGE_MOD
    #IMAGE_DIGEST=`docker images --digests | grep webgoat | awk -v image_pattern="$image_mod" '$1 ~ image_pattern { print $3 }' | awk -F '[:]' '{print $2}'`
    #echo $IMAGE_DIGEST

    #jf rt bdc $REPO --image-file $IMAGE_DIGEST --build-name $BUILDNAME --build-number $TIMESTAMP --project $PROJECTKEY

    #jf rt bp $BUILDNAME $TIMESTAMP --project $PROJECTKEY
    

}

echo "Script was called with $@"
if [[ "$1" == "base" ]]; then
    callBase
elif [[ "$1" == "dockerized" ]]; then
    callDockerized
else
    echo "Nothing here"
fi


