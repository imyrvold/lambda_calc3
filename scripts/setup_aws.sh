#!/bin/sh

FUNCTION_NAME=Calc
API_NAME=LambdaCalc
RESOURCE_NAME=calc
POLICY_NAME=lambda_execute
ROLE_NAME=lambda_invoke_function_assume_apigw_role
VALIDATE_REQUEST_PARAMETER_NAME=validate-request-parameters
REGION=eu-west-1
STAGE=test

function fail() {
    echo $2
    exit $1
}

echo "build lambda project..."
docker run \
    --rm \
    --volume "$(pwd)/:/src" \
    --workdir "/src/" \
    swift:5.3.2-amazonlinux2 \
    swift build --product calc -c release -Xswiftc -static-stdlib

echo "pack lambda.zip..."
scripts/package.sh ${RESOURCE_NAME}

echo "1 iam create-policy..."
aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file://Invoke-Function-Role-Trust-Policy.json \
    > results/aws/create-policy.json

[ $? == 0 ] || fail 1 "Failed: AWS / iam / create-policy"

POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName==\`${POLICY_NAME}\`].Arn" --output text --region ${REGION})

echo "2 iam create-role..."
aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document file://Assume-STS-Role-Policy.json \
    > results/aws/create-role.json

[ $? == 0 ] || fail 2 "Failed: AWS / iam / create-role"

echo "3 iam attach-role-policy..."
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN \
    > results/aws/attach-role-policy.json

[ $? == 0 ] || fail 3 "Failed: AWS / iam / attach-role-policy"

ROLE_ARN=$(aws iam list-roles --query "Roles[?RoleName==\`${ROLE_NAME}\`].Arn" --output text --region ${REGION})

sleep 10

echo "4 lambda create-function..."
aws lambda create-function \
    --region ${REGION} \
    --function-name ${FUNCTION_NAME} \
    --runtime provided.al2 \
    --handler lambda.run \
    --memory-size 128 \
    --zip-file fileb://.build/lambda/calc/lambda.zip \
    --role ${ROLE_ARN} \
    > results/aws/lambda-create-function.json

[ $? == 0 ] || fail 4 "Failed: AWS / lambda / create-function"

LAMBDA_ARN=$(aws lambda list-functions --query "Functions[?FunctionName==\`${FUNCTION_NAME}\`].FunctionArn" --output text --region ${REGION})

echo "5 apigateway create-rest-api..."
aws apigateway create-rest-api \
    --region ${REGION} \
    --name ${API_NAME} \
    --endpoint-configuration types=REGIONAL \
    > results/aws/create-rest-api.json

[ $? == 0 ] || fail 5 "Failed: AWS / apigateway / create-rest-api"

API_ID=$(aws apigateway get-rest-apis --query "items[?name==\`${API_NAME}\`].id" --output text --region ${REGION})
PARENT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/`].id' --output text --region ${REGION})

echo "6 apigateway create-resource..."
aws apigateway create-resource \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --parent-id ${PARENT_RESOURCE_ID} \
    --path-part ${RESOURCE_NAME} \
    > results/aws/create-resource.json

[ $? == 0 ] || fail 6 "Failed: AWS / apigateway / create-resource"

RESOURCE_ID=$(aws apigateway get-resources --rest-api-id ${API_ID} --query "items[?path==\`/$RESOURCE_NAME\`].id" --output text --region ${REGION})

echo "7 apigateway create-request-validator..."
aws apigateway create-request-validator \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --name ${VALIDATE_REQUEST_PARAMETER_NAME} \
    --validate-request-parameters \
    > results/aws/create-request-parameters-validator.json

[ $? == 0 ] || fail 7 "Failed: AWS / apigateway / create-request-validator"

REQUEST_VALIDATOR_PARAMETERS_ID=$(aws apigateway get-request-validators --rest-api-id ${API_ID} --query "items[?name==\`$VALIDATE_REQUEST_PARAMETER_NAME\`].id" --output text --region ${REGION})

#Integration 1
# Resources /calc/GET

echo "8 apigateway put-method..."
aws apigateway put-method \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --authorization-type NONE \
    --request-validator-id ${REQUEST_VALIDATOR_PARAMETERS_ID} \
    --request-parameters "method.request.querystring.operand1=true,method.request.querystring.operand2=true,method.request.querystring.operator=true" \
    > results/aws/put-get-method.json

[ $? == 0 ] || fail 8 "Failed: AWS / apigateway / put-method"

echo "9 apigateway put-method-response..."
aws apigateway put-method-response \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --status-code 200 \
    --response-models application/json=Empty \
    > results/aws/put-method-response.json

[ $? == 0 ] || fail 9 "Failed: AWS / apigateway / put-method-response"

echo "10 apigateway put-integration..."
aws apigateway put-integration \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --type AWS \
    --integration-http-method POST \
    --uri arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations \
    --credentials ${ROLE_ARN} \
    --passthrough-behavior WHEN_NO_TEMPLATES \
    --request-templates file://request-templates.json \
    > results/aws/put-get-integration.json

[ $? == 0 ] || fail 10 "Failed: AWS / apigateway / put-integration"

echo "11 apigateway put-integration-response..."
aws apigateway put-integration-response \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --status-code 200 \
    --response-templates application/json="" \
    > results/aws/put-get-integration-response.json

[ $? == 0 ] || fail 11 "Failed: AWS / apigateway / put-integration-response"

echo "12 apigateway create-model..."
aws apigateway create-model \
    --rest-api-id ${API_ID} \
    --name ${INPUT_MODEL_NAME} \
    --content-type application/json \
    --schema "{\"type\": \"object\", \"properties\": { \"a\" : { \"type\": \"number\" },  \"b\" : { \"type\": \"number\" }, \"op\" : { \"type\": \"string\" }}, \"title\": \"${INPUT_MODEL_NAME}\"}" \
    > results/aws/create-input-model.json

[ $? == 0 ] || fail 12 "Failed: AWS / apigateway / create-model"

echo "13 apigateway create-model..."
aws apigateway create-model \
    --rest-api-id ${API_ID} \
    --name ${OUTPUT_MODEL_NAME} \
    --content-type application/json \
    --schema "{ \"type\": \"object\", \"properties\": { \"c\" : { \"type\": \"number\"}}, \"title\":\"${OUTPUT_MODEL_NAME}\"}" \
    > results/aws/create-output-model.json

[ $? == 0 ] || fail 13 "Failed: AWS / apigateway / create-model"

echo "14 apigateway create-model..."
aws apigateway create-model \
    --rest-api-id ${API_ID} \
    --name ${RESULT_MODEL_NAME} \
    --content-type application/json \
    --schema "{ \"type\": \"object\", \"properties\": { \"input\":{ \"\$ref\": \"https://apigateway.amazonaws.com/restapis/${API_ID}/models/${INPUT_MODEL_NAME}\"}, \"output\":{\"\$ref\": \"https://apigateway.amazonaws.com/restapis/${API_ID}/models/Output\"}}, \"title\": \"${OUTPUT_MODEL_NAME}\"}" \
    > results/aws/create-result-model.json
 
 [ $? == 0 ] || fail 14 "Failed: AWS / apigateway / create-model"

echo "15 apigateway put-method..."
aws apigateway put-method \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method POST \
    --authorization-type NONE \
    > results/aws/put-post-method.json

[ $? == 0 ] || fail 15 "Failed: AWS / apigateway / put-method"

echo "16 apigateway put-method-response..."
aws apigateway put-method-response \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method POST \
    --status-code 200 \
    --response-models application/json=Empty \
    > results/aws/put-method-response.json

[ $? == 0 ] || fail 16 "Failed: AWS / apigateway / put-method"

echo "17 apigateway put-integration..."
aws apigateway put-integration \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method POST \
    --type AWS \
    --integration-http-method POST \
    --uri arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations \
    --credentials ${ROLE_ARN} \
    --passthrough-behavior WHEN_NO_MATCH \
    > results/aws/put-post-integration.json

[ $? == 0 ] || fail 17 "Failed: AWS / apigateway / put-integration"

echo "18 apigateway put-integration-response..."
aws apigateway put-integration-response \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method POST \
    --status-code 200 \
    --response-templates application/json="" \
    > results/aws/put-post-integration-response.json

[ $? == 0 ] || fail 18 "Failed: AWS / apigateway / put-integration-response"

# Integration 3
# Resources /{operand1}/{operand2}/{operator} GET

echo "19 apigateway create-resource..."
aws apigateway create-resource \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --parent-id ${RESOURCE_ID} \
    --path-part {operand1} \
    > results/aws/create-resource-operand1.json

[ $? == 0 ] || fail 19 "Failed: AWS / apigateway / create-resource"

RESOURCE_OPERAND1_PATH="$RESOURCE_NAME/{operand1}"
RESOURCE_OPERAND1_ID=$(aws apigateway get-resources --rest-api-id ${API_ID} --query "items[?path==\`/$RESOURCE_OPERAND1_PATH\`].id" --output text --region ${REGION})

echo "20 apigateway create-resource..."
aws apigateway create-resource \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --parent-id ${RESOURCE_OPERAND1_ID} \
    --path-part {operand2} \
    > results/aws/create-resource-operand2.json

[ $? == 0 ] || fail 20 "Failed: AWS / apigateway / create-resource"

RESOURCE_OPERAND2_PATH="$RESOURCE_OPERAND1_PATH/{operand2}"
RESOURCE_OPERAND2_ID=$(aws apigateway get-resources --rest-api-id ${API_ID} --query "items[?path==\`/$RESOURCE_OPERAND2_PATH\`].id" --output text --region ${REGION})

echo "21 apigateway create-resource..."
aws apigateway create-resource \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --parent-id ${RESOURCE_OPERAND2_ID} \
    --path-part {operator} \
    > results/aws/create-resource-operator.json

[ $? == 0 ] || fail 21 "Failed: AWS / apigateway / create-resource"

RESOURCE_OPERATOR_PATH="$RESOURCE_OPERAND2_PATH/{operator}"
RESOURCE_OPERATOR_ID=$(aws apigateway get-resources --rest-api-id ${API_ID} --query "items[?path==\`/$RESOURCE_OPERATOR_PATH\`].id" --output text --region ${REGION})

echo "22 apigateway put-method..."
aws apigateway put-method \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_OPERATOR_ID} \
    --http-method GET \
    --authorization-type NONE \
    --request-parameters "method.request.path.operand1=true,method.request.path.operand2=true,method.request.path.operator=true" \
    > results/aws/put-get-path-method.json

[ $? == 0 ] || fail 22 "Failed: AWS / apigateway / put-method"

echo "23 apigateway put-method-response..."
aws apigateway put-method-response \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_OPERATOR_ID} \
    --http-method GET \
    --status-code 200 \
    --response-models application/json=Empty \
    > results/aws/put-method-response2.json

[ $? == 0 ] || fail 23 "Failed: AWS / apigateway / put-method-response"

echo "24 apigateway put-integration..."
aws apigateway put-integration \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_OPERATOR_ID} \
    --http-method GET \
    --type AWS \
    --integration-http-method POST \
    --uri arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations \
    --credentials ${ROLE_ARN} \
    --content-handling CONVERT_TO_TEXT \
    --passthrough-behavior WHEN_NO_TEMPLATES \
    --request-templates file://request-templates2.json \
    > results/aws/put-get-integration2.json

[ $? == 0 ] || fail 24 "Failed: AWS / apigateway / put-integration"

echo "25 apigateway put-integration-response..."
aws apigateway put-integration-response \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_OPERATOR_ID} \
    --http-method GET \
    --status-code 200 \
    --response-templates application/json="" \
    > results/aws/put-get-integration-response2.json

[ $? == 0 ] || fail 25 "Failed: AWS / apigateway / put-integration-response"

echo "26 apigateway create-deployment..."
aws apigateway create-deployment \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --stage-name ${STAGE} \
    > results/aws/create-deployment.json

[ $? == 0 ] || fail 26 "Failed: AWS / apigateway / create-deployment"

ENDPOINT=https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc
echo "API available at: ${ENDPOINT}"

echo
echo "Integration 1"
echo "Testing GET with query parameters:"
echo "27 / 9"
cat << EOF
curl -i --request GET \
https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc\?operand1\=27\&operand2\=9\&operator\=div
EOF
echo

curl -i --request GET \
https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc\?operand1\=27\&operand2\=9\&operator\=div

echo
echo
echo "Integration 2"
echo "Testing POST:"
echo "8 + 6"
cat << EOF
curl -i --request POST \
--header "Content-Type: application/json" \
--data '{"a": 8, "b": 6, "op": "add"}' \
https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc
EOF
echo

curl -i --request POST \
--header "Content-Type: application/json" \
--data '{"a": 8, "b": 6, "op": "add"}' \
https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc

echo
echo
echo "Integration 3"
echo "Testing GET with path parameters:"
echo "5 * 8"
cat << EOF
curl -i --request GET \
https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc/5/8/\mul
EOF
echo

curl -i --request GET \
https://${API_ID}.execute-api.eu-west-1.amazonaws.com/${STAGE}/calc/5/8/\mul
